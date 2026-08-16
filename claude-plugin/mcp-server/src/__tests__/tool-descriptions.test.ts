import { describe, it, expect } from 'vitest';
import { allTools } from '../tools/index.js';
import { rpcPortProperty } from '../tools/common.js';

/**
 * Tool descriptions are sent in full on every turn, so their size is a running cost and their
 * accuracy steers which tool the model reaches for. These guard both.
 */
describe('tool descriptions', () => {
  it('does not teach the edit+bp workflow that nvim_load_buffer replaced', () => {
    // The LSP tools used to end with 'Background workflow: nvim_execute("edit file.ts") →
    // nvim_execute("bp")', which nvim_load_buffer's own description tells the model not to do.
    for (const tool of allTools) {
      expect(
        tool.description,
        `${tool.name} still describes the superseded workflow`
      ).not.toContain('nvim_execute("edit');
    }
  });

  it('points the LSP tools at nvim_load_buffer instead', () => {
    const lspTools = allTools.filter(
      (t) => t.name.startsWith('nvim_lsp_') || t.name === 'nvim_diagnostics'
    );

    expect(lspTools.length).toBeGreaterThan(0);
    for (const tool of lspTools) {
      expect(tool.description, `${tool.name} should name nvim_load_buffer`).toContain(
        'nvim_load_buffer'
      );
    }
  });

  it('keeps the rpc_port description short, since every tool carries a copy', () => {
    // ~110 chars across ~28 tools is already ~3k characters of context per turn. The previous
    // 193-char version cost 5.4k.
    expect(rpcPortProperty.rpc_port.description.length).toBeLessThanOrEqual(130);
  });

  it('cross-references the two window-inspection tools so the choice is obvious', () => {
    const byName = Object.fromEntries(allTools.map((t) => [t.name, t.description]));

    expect(byName.nvim_get_window_info).toContain('nvim_get_window_view');
    expect(byName.nvim_get_window_view).toContain('nvim_get_window_info');
  });

  it('says that nvim_get_info returns no content, so nvim_get_buffer is not skipped', () => {
    const info = allTools.find((t) => t.name === 'nvim_get_info')?.description ?? '';

    expect(info).toContain('nvim_get_buffer');
    expect(info.toLowerCase()).toContain('no content');
  });
});
