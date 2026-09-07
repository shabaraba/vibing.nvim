import { describe, it, expect } from 'vitest';
import * as fs from 'fs';
import * as path from 'path';
import { fileURLToPath } from 'url';
import { READ_ONLY_METHODS } from '../read-only-methods.js';

/**
 * The handler *sources*, found by walking up to the package root — this spec is compiled into
 * `dist/` and run from there too, where `../handlers` holds only `.d.ts` files.
 */
function handlersDir(): string {
  let dir = path.dirname(fileURLToPath(import.meta.url));
  for (let i = 0; i < 5; i++) {
    const candidate = path.join(dir, 'src', 'handlers');
    if (fs.existsSync(candidate)) {
      return candidate;
    }
    dir = path.dirname(dir);
  }
  throw new Error('could not locate src/handlers from ' + fileURLToPath(import.meta.url));
}

/**
 * Every method a handler asks for by name, taken from the source rather than a hand-kept list —
 * a new one has to be classified here before this file passes again.
 */
function calledMethods(): string[] {
  const found = new Set<string>();
  const dir = handlersDir();
  for (const file of fs.readdirSync(dir).filter((f) => f.endsWith('.ts'))) {
    const source = fs.readFileSync(path.join(dir, file), 'utf8');
    for (const match of source.matchAll(/callNeovim\(\s*'([a-z_]+)'/g)) {
      found.add(match[1]);
    }
  }
  if (found.size === 0) {
    throw new Error('no callNeovim() methods found — the scan, not the code, is broken');
  }
  return [...found].sort();
}

/**
 * The methods that change Neovim state, and so must never be pointed at a registry-guessed
 * instance. This is exactly the set `requireRpcPort` used to enforce in each tool's schema.
 */
const STATE_CHANGING_METHODS = [
  'annotate',
  'answer_approval',
  'ask_user_question',
  'buf_set_lines',
  'clear_annotations',
  'clear_highlight',
  'create_chat',
  'dap_evaluate',
  'dap_get_stack_trace',
  'dap_get_state',
  'dap_get_variables',
  'dap_set_breakpoint',
  'execute',
  'focus_window',
  'highlight_range',
  'load_buffer',
  'send_message',
  'set_cursor_position',
  'set_qflist',
  'set_window_height',
  'set_window_width',
  'win_open_file',
  'win_set_buf',
];

describe('read-only method allowlist', () => {
  it('classifies every method the handlers call', () => {
    const classified = new Set([...READ_ONLY_METHODS, ...STATE_CHANGING_METHODS]);
    const unclassified = calledMethods().filter((m) => !classified.has(m));

    // A new method defaults to "writer" in rpc.ts, so this failure is a reminder to say which it
    // is here, not a bug in itself.
    expect(unclassified, 'unclassified RPC methods').toEqual([]);
  });

  it('never lets a state-changing method through as a read', () => {
    for (const method of STATE_CHANGING_METHODS) {
      expect(READ_ONLY_METHODS.has(method), `${method} must not be read-only`).toBe(false);
    }
  });

  it('lists no method no handler calls, so a rename cannot leave a dead entry', () => {
    const called = new Set(calledMethods());
    for (const method of READ_ONLY_METHODS) {
      expect(called.has(method), `${method} is not called by any handler`).toBe(true);
    }
  });
});
