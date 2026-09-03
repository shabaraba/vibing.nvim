// scripts/screenshot/ is reached by no other gate: `check` compiles lua/ only, eslint matches
// js/mjs/ts, and prettier matches js/ts/json/md/yml — none of them touch .py or .sh. So the two
// Python tools there could break without a word, and one of them is the safety net that catches
// a silently clipped screenshot. This pins what each is relied on for.
//
// The fixtures are built here rather than committed, so a change to the renderer's output cannot
// be "fixed" by regenerating a golden file that no longer describes anything.

import assert from 'node:assert/strict';
import { execFileSync, spawnSync } from 'node:child_process';
import { mkdtempSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { crc32, deflateSync } from 'node:zlib';

const ROOT = path.resolve(import.meta.dirname, '..');
const ANSI2HTML = path.join(ROOT, 'scripts/screenshot/ansi2html.py');
const PXBOX = path.join(ROOT, 'scripts/screenshot/pxbox.py');

// python3 is a hard requirement of both tools, so a missing interpreter is a real failure rather
// than a reason to skip: a test that quietly runs nothing is the exact dead gate this file exists
// to prevent.
const PYTHON = 'python3';

const FONT_PX = 15;
const LINE_PX = 21;
const PAD_PX = 14;

function ansi2html(dump, cols, extra = []) {
  return execFileSync(
    PYTHON,
    [
      ANSI2HTML,
      '--cols',
      String(cols),
      '--font-px',
      String(FONT_PX),
      '--line-px',
      String(LINE_PX),
      '--pad-px',
      String(PAD_PX),
      ...extra,
    ],
    { input: dump, encoding: 'utf8' }
  );
}

/** Every `<i>` cell in the rendered page, as {left, top, width, style, char}. */
function cellsOf(html) {
  return [...html.matchAll(/<i style="([^"]*)">([^<]*)<\/i>/g)].map(([, style, char]) => {
    const num = (name) => {
      const m = style.match(new RegExp(`(?:^|;)${name}:(-?[0-9.]+)px`));
      return m ? Number(m[1]) : null;
    };
    return { left: num('left'), top: num('top'), width: num('width'), style, char };
  });
}

const SGR = (...params) => `[${params.join(';')}m`;

test('ansi2html --print-size is the single source of the viewport geometry', () => {
  // capture.sh sizes the browser window from this. It used to compute the character advance
  // itself, so the two could disagree and the screenshot would be cut off with no error.
  const out = execFileSync(
    PYTHON,
    [
      ANSI2HTML,
      '--print-size',
      '--cols',
      '150',
      '--rows',
      '40',
      '--font-px',
      String(FONT_PX),
      '--line-px',
      String(LINE_PX),
      '--pad-px',
      String(PAD_PX),
    ],
    { encoding: 'utf8' }
  );
  const [width, height] = out.trim().split(/\s+/).map(Number);

  assert.equal(height, 40 * LINE_PX + 2 * PAD_PX);
  // The width must match what the page itself lays out, whatever the advance happens to be.
  const html = ansi2html('x'.repeat(150), 150);
  const page = html.match(/#t\{[^}]*width:([0-9.]+)px/);
  assert.ok(page, 'the page should declare its own width');
  assert.equal(width, Math.round(Number(page[1])) + 2 * PAD_PX);
});

test('ansi2html --print-size refuses to guess a missing --rows', () => {
  const r = spawnSync(PYTHON, [ANSI2HTML, '--print-size', '--cols', '80'], { encoding: 'utf8' });
  assert.notEqual(r.status, 0);
  assert.match(r.stderr, /--rows/);
});

test('ansi2html carries truecolor foreground and background onto the cell', () => {
  const html = ansi2html(`${SGR(38, 2, 224, 226, 234)}${SGR(48, 2, 79, 82, 88)}A`, 10);
  const [cell] = cellsOf(html);
  assert.equal(cell.char, 'A');
  assert.match(cell.style, /color:#e0e2ea/);
  assert.match(cell.style, /background:#4f5258/);
});

test('ansi2html resolves the 256-colour and base-16 forms too', () => {
  // 196 is the pure red of the colour cube; 31 is base-16 red.
  const cube = cellsOf(ansi2html(`${SGR(38, 5, 196)}A`, 10))[0];
  assert.match(cube.style, /color:#ff0000/);
  const base = cellsOf(ansi2html(`${SGR(31)}A`, 10))[0];
  assert.match(base.style, /color:#cd0000/);
});

test('ansi2html gives a wide character two columns', () => {
  // A CJK glyph advances the grid by two cells. Getting this wrong is what made a flowed <pre>
  // drift out of alignment on Japanese-heavy source and misrepresent the window layout.
  const cells = cellsOf(ansi2html('あA', 10));
  assert.equal(cells.length, 2);
  const [wide, narrow] = cells;
  assert.equal(wide.char, 'あ');
  // Compared with a tolerance because the page carries the positions rounded to 1/100 px: the
  // advance is 9.0345px, so doubling the *printed* 9.03 gives 18.06 where the wide cell prints
  // 18.07. Each value can be off by half a hundredth, and doubling one doubles its share.
  assert.ok(
    Math.abs(wide.width - 2 * narrow.width) <= 0.02,
    `wide cell ${wide.width} should be twice ${narrow.width}`
  );
  // This one is exact, and is the property that actually keeps the grid aligned: the next cell
  // begins where the wide one ends, not one narrow column in.
  assert.equal(narrow.left, wide.left + wide.width);
});

test('ansi2html states an explicit cell height, so descenders are not clipped', () => {
  // Leaving the height to the line box let the statusline row's descenders fall outside the
  // box and get cut by overflow:hidden — visible only on that one row.
  const html = ansi2html('A', 10);
  const rule = html.match(/#t i\{[^}]*\}/s);
  assert.ok(rule, 'the page should carry a cell rule');
  assert.match(rule[0], new RegExp(`height:${LINE_PX}px`));
  assert.match(rule[0], new RegExp(`line-height:${LINE_PX}px`));
});

test('ansi2html emits a blank cell only when it paints something', () => {
  // Most of a terminal screen is unstyled spaces; an element each would multiply the page size
  // for nothing. A space with a background is the statusline, and must survive.
  assert.equal(cellsOf(ansi2html('   ', 10)).length, 0);
  const painted = cellsOf(ansi2html(`${SGR(48, 2, 79, 82, 88)}   `, 10));
  assert.equal(painted.length, 3);
  assert.match(painted[0].style, /background:#4f5258/);
});

test('ansi2html swaps colours for reverse video', () => {
  const [cell] = cellsOf(ansi2html(`${SGR(38, 2, 0, 0, 0)}${SGR(48, 2, 255, 0, 0)}${SGR(7)}A`, 10));
  assert.match(cell.style, /color:#ff0000/);
  assert.match(cell.style, /background:#000000/);
});

test('ansi2html drops a non-SGR escape without swallowing the colour after it', () => {
  // The scanner has to know where a CSI or OSC sequence ends. A regex that stripped escapes in
  // a pre-pass could eat the `m` that terminates the colour that follows, silently losing every
  // subsequent style on the line.
  const dump = `]0;a title[?25l${SGR(38, 2, 1, 2, 3)}A`;
  const cells = cellsOf(ansi2html(dump, 20));
  assert.equal(cells.length, 1);
  assert.equal(cells[0].char, 'A');
  assert.match(cells[0].style, /color:#010203/);
});

test('ansi2html escapes markup coming from the terminal', () => {
  const html = ansi2html('<&>', 10);
  assert.match(html, /&lt;/);
  assert.match(html, /&amp;/);
  assert.equal(cellsOf(html).length, 3);
});

// --- pxbox.py -----------------------------------------------------------------------------

const BPP = 3; // 8-bit RGB

/**
 * PNG scanlines with a chosen filter per row.
 *
 * Encoding the filters here rather than always writing type 0 is what makes the decoder test
 * worth anything: a real browser screenshot is filtered per row, and pxbox.py reverses all five
 * types by hand.
 */
function encodeScanlines(width, height, paint, filterFor) {
  const stride = width * BPP;
  const parts = [];
  let prev = Buffer.alloc(stride);
  for (let y = 0; y < height; y++) {
    const line = Buffer.alloc(stride);
    for (let x = 0; x < width; x++) {
      const [r, g, b] = paint(x, y);
      line[x * BPP] = r;
      line[x * BPP + 1] = g;
      line[x * BPP + 2] = b;
    }
    const filter = filterFor(y);
    const encoded = Buffer.alloc(stride);
    for (let i = 0; i < stride; i++) {
      const left = i >= BPP ? line[i - BPP] : 0;
      const up = prev[i];
      const upLeft = i >= BPP ? prev[i - BPP] : 0;
      let predictor = 0;
      if (filter === 1) {
        predictor = left;
      } else if (filter === 2) {
        predictor = up;
      } else if (filter === 3) {
        predictor = (left + up) >> 1;
      } else if (filter === 4) {
        const p = left + up - upLeft;
        const pa = Math.abs(p - left);
        const pb = Math.abs(p - up);
        const pc = Math.abs(p - upLeft);
        predictor = pa <= pb && pa <= pc ? left : pb <= pc ? up : upLeft;
      }
      encoded[i] = (line[i] - predictor) & 0xff;
    }
    parts.push(Buffer.from([filter]), encoded);
    prev = line;
  }
  return Buffer.concat(parts);
}

/** A minimal 8-bit RGB PNG, so the fixture does not come from the decoder under test. */
function png(width, height, paint, filterFor = () => 0) {
  const raw = encodeScanlines(width, height, paint, filterFor);
  const chunk = (type, body) => {
    const head = Buffer.alloc(8);
    head.writeUInt32BE(body.length, 0);
    head.write(type, 4, 'ascii');
    const crc = Buffer.alloc(4);
    crc.writeUInt32BE(crc32(Buffer.concat([Buffer.from(type, 'ascii'), body])), 0);
    return Buffer.concat([head, body, crc]);
  };
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(width, 0);
  ihdr.writeUInt32BE(height, 4);
  ihdr[8] = 8; // bit depth
  ihdr[9] = 2; // colour type: RGB
  return Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    chunk('IHDR', ihdr),
    chunk('IDAT', deflateSync(raw)),
    chunk('IEND', Buffer.alloc(0)),
  ]);
}

const BG = [20, 22, 27];
const INK = [224, 226, 234];

function writePng(name, width, height, paint, filterFor) {
  const file = path.join(mkdtempSync(path.join(tmpdir(), 'vibing-pxbox-')), name);
  writeFileSync(file, png(width, height, paint, filterFor));
  return file;
}

function pxbox(file, expectHeight) {
  const args = [PXBOX, file];
  if (expectHeight !== undefined) args.push('--expect-height', String(expectHeight));
  return spawnSync(PYTHON, args, { encoding: 'utf8' });
}

test('pxbox reports the exact bounding box of what was painted', () => {
  // x 10..19, y 5..24 — deliberately not touching any edge, so an off-by-one in the row filter
  // or stride would move it.
  const file = writePng('box.png', 40, 30, (x, y) =>
    x >= 10 && x <= 19 && y >= 5 && y <= 24 ? INK : BG
  );
  const r = pxbox(file);
  assert.equal(r.status, 0, r.stderr);
  assert.match(r.stdout, /x 10\.\.19 \(w=10\)/);
  assert.match(r.stdout, /y 5\.\.24 \(h=20\)/);
});

test('pxbox fails when the painted region is shorter than the grid implies', () => {
  // This is the whole point of the tool: a capture clipped from the bottom is a plausible
  // screenshot of a slightly different screen, and the eye does not catch it.
  //
  // Both fixtures leave a margin, because the page being measured always has one — ansi2html.py
  // pads the grid — and content that ran to the very edge would be a different image than this
  // tool is ever pointed at.
  const band = (from, to) => (x, y) => (y >= from && y <= to && x >= 4 && x <= 35 ? INK : BG);

  const clipped = writePng('clipped.png', 40, 60, band(4, 13));
  const short = pxbox(clipped, 40);
  assert.notEqual(short.status, 0);
  assert.match(short.stdout + short.stderr, /clipped/);

  const full = writePng('full.png', 40, 60, band(4, 53));
  assert.equal(pxbox(full, 40).status, 0);
});

test('pxbox fails rather than reports an empty box on a blank capture', () => {
  const blank = writePng('blank.png', 20, 20, () => BG);
  const r = pxbox(blank);
  assert.notEqual(r.status, 0);
  assert.match(r.stdout, /nothing painted/);
});

test('pxbox reverses every PNG row filter', () => {
  // A browser screenshot is filtered per row, and pxbox.py undoes all five types by hand. A
  // wrong Paeth or Average reconstruction corrupts the image and moves the box, so the same
  // rectangle has to come back whichever filter carried it.
  const paint = (x, y) => (x >= 8 && x <= 31 && y >= 4 && y <= 19 ? INK : BG);
  for (const filter of [0, 1, 2, 3, 4]) {
    const file = writePng(`filter${filter}.png`, 64, 40, paint, () => filter);
    const r = pxbox(file);
    assert.equal(r.status, 0, `filter ${filter}: ${r.stderr}`);
    assert.match(r.stdout, /x 8\.\.31 \(w=24\)/, `filter ${filter} moved the box`);
    assert.match(r.stdout, /y 4\.\.19 \(h=16\)/, `filter ${filter} moved the box`);
  }

  // Mixed filters exercise the "previous row" state the reconstruction carries between rows.
  const mixed = writePng('mixed.png', 64, 40, paint, (y) => y % 5);
  const r = pxbox(mixed);
  assert.equal(r.status, 0, r.stderr);
  assert.match(r.stdout, /x 8\.\.31 \(w=24\)/);
  assert.match(r.stdout, /y 4\.\.19 \(h=16\)/);
});

test('pxbox takes the background from the border, not from one pixel', () => {
  // The regression this guards: a full-width painted band crossing the middle of the image used
  // to be read as the background, because the sample point sat inside it.
  const file = writePng('midband.png', 40, 60, (x, y) => (y >= 25 && y <= 34 ? INK : BG));
  const r = pxbox(file);
  assert.equal(r.status, 0, r.stderr);
  assert.match(r.stdout, /y 25\.\.34 \(h=10\)/);
  assert.match(r.stdout, new RegExp(`bg=\\(${BG.join(', ')}\\)`));
});
