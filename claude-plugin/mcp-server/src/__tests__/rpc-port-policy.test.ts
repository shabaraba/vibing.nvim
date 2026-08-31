import { describe, it, expect } from 'vitest';
import { allTools } from '../tools/index.js';

/**
 * Reads may omit rpc_port and fall back to the instance registry; anything that changes state
 * must name its target. The reason is that this server is installed at Claude Code's *user*
 * scope, so every Claude Code session on the machine sees these tools — including sessions with
 * nothing to do with vibing.nvim, which have no port to pass. See requireRpcPort in
 * tools/common.ts.
 *
 * The list below is the *reads*, not the writes, so the rule fails closed: a tool nobody
 * classified is treated as state-changing and must require the port. Listing the writes instead
 * meant every new state-changing tool broke this test on arrival even though it was correct —
 * which is exactly what happened when nvim_highlight_range landed.
 */
const READ_ONLY_TOOLS = [
  'nvim_diagnostics',
  // Stays a read despite `file_path` opening a chat buffer that was closed (#641). The rule
  // exists so a state change cannot land on an instance the caller did not name, and this one
  // cannot: the registry fallback answers only when exactly one Neovim is live. What it leaves
  // behind is a buffer for a chat file the user already has on disk.
  'nvim_get_buffer',
  'nvim_get_cursor',
  'nvim_get_info',
  'nvim_get_visual_selection',
  'nvim_get_window_info',
  'nvim_get_window_view',
  'nvim_list_buffers',
  'nvim_list_tabpages',
  'nvim_list_windows',
  'nvim_lsp_call_hierarchy_incoming',
  'nvim_lsp_call_hierarchy_outgoing',
  'nvim_lsp_definition',
  'nvim_lsp_document_symbols',
  'nvim_lsp_hover',
  'nvim_lsp_references',
  'nvim_lsp_type_definition',
];

/**
 * Reading the registry is how you find out which ports exist, so this one cannot take a port at
 * all — it is neither a read that may omit it nor a write that must supply it.
 */
const PORTLESS_TOOLS = ['nvim_list_instances'];

const requiredOf = (tool: { inputSchema: unknown }) =>
  (tool.inputSchema as { required?: string[] })?.required ?? [];

const acceptsRpcPort = (tool: { inputSchema: unknown }) =>
  Boolean((tool.inputSchema as { properties?: Record<string, unknown> })?.properties?.rpc_port);

describe('rpc_port policy', () => {
  it('requires rpc_port on every tool that is not a known read', () => {
    const writes = allTools.filter(
      (t) => !READ_ONLY_TOOLS.includes(t.name) && !PORTLESS_TOOLS.includes(t.name)
    );

    expect(writes.length).toBeGreaterThan(0);
    for (const tool of writes) {
      expect(requiredOf(tool), `${tool.name} must require rpc_port`).toContain('rpc_port');
    }
  });

  it('leaves rpc_port optional on the reads', () => {
    for (const name of READ_ONLY_TOOLS) {
      const tool = allTools.find((t) => t.name === name);
      expect(tool, `${name} is not registered`).toBeDefined();
      expect(acceptsRpcPort(tool!), `${name} should accept rpc_port`).toBe(true);
      expect(requiredOf(tool!), `${name} should not require rpc_port`).not.toContain('rpc_port');
    }
  });

  it('does not offer rpc_port on the tool that exists to find ports', () => {
    for (const name of PORTLESS_TOOLS) {
      const tool = allTools.find((t) => t.name === name);
      expect(tool, `${name} is not registered`).toBeDefined();
      expect(acceptsRpcPort(tool!), `${name} should not take rpc_port`).toBe(false);
    }
  });
});
