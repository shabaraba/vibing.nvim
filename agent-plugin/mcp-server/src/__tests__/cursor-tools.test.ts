import { describe, it, expect, vi, beforeEach } from 'vitest';
import { allTools } from '../tools/index.js';
import { handlers } from '../handlers/index.js';
import * as rpc from '../rpc.js';

vi.mock('../rpc.js', () => ({
  callNeovim: vi.fn(),
}));

function call(args: Record<string, unknown>) {
  return handlers.nvim_set_cursor(args);
}

describe('nvim_set_cursor', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    vi.mocked(rpc.callNeovim).mockResolvedValue({ success: true });
  });

  describe('registration', () => {
    it('accepts an optional winnr alongside the required line', () => {
      const tool = allTools.find((t) => t.name === 'nvim_set_cursor');
      const inputSchema = tool?.inputSchema as {
        required?: string[];
        properties: Record<string, unknown>;
      };

      expect(inputSchema.properties.winnr).toBeDefined();
      expect(inputSchema.required).toContain('line');
      expect(inputSchema.required).not.toContain('winnr');
    });

    it('tells the model why winnr matters after nvim_win_open_file', () => {
      // Without this the model has no way to know the open-then-jump sequence needs it: the
      // tool call succeeds either way, it just moves the wrong window.
      const tool = allTools.find((t) => t.name === 'nvim_set_cursor');
      expect(tool?.description).toMatch(/winnr/);
      expect(tool?.description).toMatch(/nvim_win_open_file/);
    });
  });

  describe('forwarding', () => {
    it('passes winnr through to the Neovim instance', async () => {
      await call({ line: 12, col: 2, winnr: 1002, rpc_port: 9876 });

      expect(rpc.callNeovim).toHaveBeenCalledWith(
        'set_cursor_position',
        { line: 12, col: 2, winnr: 1002 },
        9876
      );
    });

    it('leaves winnr undefined when the caller omits it, so the active window is used', async () => {
      await call({ line: 3, rpc_port: 9876 });

      expect(rpc.callNeovim).toHaveBeenCalledWith(
        'set_cursor_position',
        { line: 3, col: undefined, winnr: undefined },
        9876
      );
    });

    it('names the window it moved, so a wrong-window call is visible in the result', async () => {
      const withWin = await call({ line: 12, winnr: 1002, rpc_port: 9876 });
      expect(withWin.content[0].text).toBe('Cursor moved to line 12 in window 1002');

      const withoutWin = await call({ line: 12, rpc_port: 9876 });
      expect(withoutWin.content[0].text).toBe('Cursor moved to line 12');
    });

    it('still rejects a call with no line', async () => {
      await expect(call({ winnr: 1002, rpc_port: 9876 })).rejects.toThrow(
        'Missing required parameter: line'
      );
      expect(rpc.callNeovim).not.toHaveBeenCalled();
    });
  });
});
