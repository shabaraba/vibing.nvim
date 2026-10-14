/**
 * HTML → readable text, with no dependency.
 *
 * `pi-extension/` is compiled by the repository root's typescript and declares no dependencies of
 * its own, so there is no `turndown` or `cheerio` here. That is a deliberate trade: a real parser
 * would produce better markdown, and a second lockfile in this directory would then need its own
 * `audit:deps` and Dependabot coverage for a tool whose output a model reads approximately anyway.
 *
 * What it must get right is the part that is not cosmetic: `<script>` and `<style>` bodies have to
 * go *before* tags are stripped, or their contents arrive as prose and a page of minified
 * JavaScript reads to the model as the article.
 */

/** The named entities that actually appear in prose. Numeric ones are handled generically. */
const NAMED_ENTITIES: Record<string, string> = {
  amp: '&',
  lt: '<',
  gt: '>',
  quot: '"',
  apos: "'",
  nbsp: ' ',
  mdash: '—',
  ndash: '–',
  hellip: '…',
  rsquo: '’',
  lsquo: '‘',
  rdquo: '”',
  ldquo: '“',
};

function decodeEntities(text: string): string {
  return text.replace(/&(#x?[0-9a-fA-F]+|[a-zA-Z]+);/g, (whole, body: string) => {
    if (body.startsWith('#')) {
      const code =
        body[1] === 'x' || body[1] === 'X' ? parseInt(body.slice(2), 16) : Number(body.slice(1));
      return Number.isFinite(code) && code > 0 ? String.fromCodePoint(code) : whole;
    }
    return NAMED_ENTITIES[body.toLowerCase()] ?? whole;
  });
}

/** Block-level tags whose boundaries are the only structure worth keeping. */
const BLOCK_TAGS = 'p|div|section|article|header|footer|li|tr|h[1-6]|blockquote|pre|table|ul|ol';

export function htmlToText(html: string): string {
  const withoutHead = html
    .replace(/<!--[\s\S]*?-->/g, '')
    // `title` is in here because `htmlTitle` reads it off the original and puts it in the header;
    // left in the body it arrives again as the first words of the page, which reads as prose.
    .replace(/<(script|style|noscript|template|svg|title)\b[\s\S]*?<\/\1>/gi, ' ');

  const withBreaks = withoutHead
    .replace(/<br\s*\/?>/gi, '\n')
    .replace(new RegExp(`</(${BLOCK_TAGS})\\s*>`, 'gi'), '\n\n');

  return decodeEntities(withBreaks.replace(/<[^>]*>/g, ' '))
    .replace(/[ \t\r\f\v]+/g, ' ')
    .replace(/ *\n */g, '\n')
    .replace(/\n{3,}/g, '\n\n')
    .trim();
}

/** `<title>`, when the page has one, so a truncated body still says what it was. */
export function htmlTitle(html: string): string | undefined {
  const match = html.match(/<title[^>]*>([\s\S]*?)<\/title>/i);
  if (!match) return undefined;
  const title = decodeEntities(match[1]).replace(/\s+/g, ' ').trim();
  return title === '' ? undefined : title;
}
