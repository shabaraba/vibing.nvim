import { describe, it, expect, vi, beforeEach } from 'vitest';
import { allTools } from '../tools/index.js';
import { handlers } from '../handlers/index.js';
import * as rpc from '../rpc.js';

vi.mock('../rpc.js', () => ({
  callNeovim: vi.fn(),
}));

describe('nvim_lsp', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    vi.mocked(rpc.callNeovim).mockResolvedValue({ ok: true });
  });

  it('replaces the per-method LSP tools with one', () => {
    const names = allTools.map((t) => t.name);
    expect(names).toContain('nvim_lsp');
    expect(names.filter((n) => n.startsWith('nvim_lsp_') || n === 'nvim_diagnostics')).toEqual([]);
  });

  it.each([
    ['definition', 'lsp_definition'],
    ['references', 'lsp_references'],
    ['hover', 'lsp_hover'],
    ['type_definition', 'lsp_type_definition'],
    ['call_hierarchy_incoming', 'lsp_call_hierarchy_incoming'],
    ['call_hierarchy_outgoing', 'lsp_call_hierarchy_outgoing'],
  ])('forwards a position method %s to %s', async (method, rpcMethod) => {
    await handlers.nvim_lsp({ method, bufnr: 3, line: 10, col: 4 });
    expect(rpc.callNeovim).toHaveBeenCalledWith(
      rpcMethod,
      { bufnr: 3, line: 10, col: 4 },
      undefined
    );
  });

  it.each([
    ['document_symbols', 'lsp_document_symbols'],
    ['diagnostics', 'diagnostics_get'],
  ])('forwards a buffer method %s to %s without a position', async (method, rpcMethod) => {
    await handlers.nvim_lsp({ method, bufnr: 3, line: 10, col: 4 });
    expect(rpc.callNeovim).toHaveBeenCalledWith(rpcMethod, { bufnr: 3 }, undefined);
  });

  it('refuses a position method without line and col before touching Neovim', async () => {
    await expect(handlers.nvim_lsp({ method: 'references', bufnr: 3 })).rejects.toThrow(
      /line and col/
    );
    expect(rpc.callNeovim).not.toHaveBeenCalled();
  });

  it('refuses an unknown method before touching Neovim', async () => {
    await expect(handlers.nvim_lsp({ method: 'rename', line: 1, col: 0 })).rejects.toThrow(
      /Unknown method/
    );
    expect(rpc.callNeovim).not.toHaveBeenCalled();
  });

  it('returns hover contents as plain text', async () => {
    vi.mocked(rpc.callNeovim).mockResolvedValue({ contents: 'fn foo()' });
    const result = await handlers.nvim_lsp({ method: 'hover', line: 1, col: 0 });
    expect(result.content[0].text).toBe('fn foo()');
  });
});
