import { describe, it, expect, vi, beforeEach } from 'vitest';
import { allTools } from '../tools/index.js';
import { handlers } from '../handlers/index.js';
import * as rpc from '../rpc.js';

vi.mock('../rpc.js', () => ({
  callNeovim: vi.fn(),
}));

const VALID_ITEM = { filename: 'lua/vibing/init.lua', lnum: 12, col: 3, text: 'entry point' };

function call(args: Record<string, unknown>) {
  return handlers.nvim_set_qflist(args);
}

describe('nvim_set_qflist', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    vi.mocked(rpc.callNeovim).mockResolvedValue({ success: true, count: 1, title: 'Code tour' });
  });

  describe('registration', () => {
    it('is registered as a tool with items and rpc_port required', () => {
      const tool = allTools.find((t) => t.name === 'nvim_set_qflist');
      expect(tool).toBeDefined();
      const inputSchema = tool?.inputSchema as {
        required?: string[];
        properties: Record<string, unknown>;
      };
      expect(inputSchema.required).toContain('items');
      expect(inputSchema.required).toContain('rpc_port');
      expect(inputSchema.properties.title).toBeDefined();
      expect(inputSchema.properties.open).toBeDefined();
    });

    it('has a handler', () => {
      expect(typeof handlers.nvim_set_qflist).toBe('function');
    });

    it('warns in its description that col is 1-based here, unlike the cursor/LSP tools', () => {
      const tool = allTools.find((t) => t.name === 'nvim_set_qflist');
      expect(tool?.description).toMatch(/1-based/);
      expect(tool?.description).toMatch(/nvim_set_cursor/);
    });
  });

  describe('forwarding', () => {
    it('passes the route through to the Neovim instance on the given port', async () => {
      await call({
        items: [VALID_ITEM],
        title: 'Code tour: auth',
        open: true,
        rpc_port: 9876,
      });

      expect(rpc.callNeovim).toHaveBeenCalledWith(
        'set_qflist',
        { items: [VALID_ITEM], title: 'Code tour: auth', open: true },
        9876
      );
    });

    it('accepts a stop with only the required fields', async () => {
      await call({ items: [{ filename: 'a.lua', lnum: 1 }], rpc_port: 9876 });

      expect(rpc.callNeovim).toHaveBeenCalledWith(
        'set_qflist',
        { items: [{ filename: 'a.lua', lnum: 1 }], title: undefined, open: undefined },
        9876
      );
    });

    it('reports the count and whether the window was opened', async () => {
      vi.mocked(rpc.callNeovim).mockResolvedValue({ success: true, count: 4, title: 'Tour' });

      const opened = await call({ items: [VALID_ITEM], open: true, rpc_port: 9876 });
      expect(opened.content[0].text).toContain('4 stop(s)');
      expect(opened.content[0].text).toContain('opened');

      const quiet = await call({ items: [VALID_ITEM], rpc_port: 9876 });
      expect(quiet.content[0].text).not.toContain('opened');
    });
  });

  describe('rejects before touching Neovim', () => {
    // Each of these would otherwise reach the editor and produce a quickfix list with dead
    // entries, which the user only discovers when :cnext lands nowhere.
    const rejected: Array<[string, Record<string, unknown>]> = [
      ['no rpc_port, which would leave the target instance ambiguous', { items: [VALID_ITEM] }],
      ['an empty route', { items: [], rpc_port: 9876 }],
      ['a stop with no filename', { items: [{ lnum: 1 }], rpc_port: 9876 }],
      ['a stop with no lnum', { items: [{ filename: 'a.lua' }], rpc_port: 9876 }],
      ['a zero lnum', { items: [{ filename: 'a.lua', lnum: 0 }], rpc_port: 9876 }],
      ['a negative lnum', { items: [{ filename: 'a.lua', lnum: -1 }], rpc_port: 9876 }],
      ['a fractional lnum', { items: [{ filename: 'a.lua', lnum: 1.5 }], rpc_port: 9876 }],
      ['a zero col', { items: [{ filename: 'a.lua', lnum: 1, col: 0 }], rpc_port: 9876 }],
      [
        'a path traversal attempt',
        { items: [{ filename: '../../../etc/passwd', lnum: 1 }], rpc_port: 9876 },
      ],
    ];

    it.each(rejected)('rejects %s', async (_label, args) => {
      await expect(call(args)).rejects.toThrow();
      expect(rpc.callNeovim).not.toHaveBeenCalled();
    });

    it('rejects the whole call when only one stop is bad', async () => {
      await expect(
        call({ items: [VALID_ITEM, { filename: 'b.lua', lnum: 0 }], rpc_port: 9876 })
      ).rejects.toThrow();
      expect(rpc.callNeovim).not.toHaveBeenCalled();
    });
  });
});
