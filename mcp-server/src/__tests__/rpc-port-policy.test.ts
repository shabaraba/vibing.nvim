import { describe, it, expect } from 'vitest';
import { allTools } from '../tools/index.js';

/**
 * Reads may omit rpc_port and fall back to the instance registry; anything that changes state
 * must name its target. The reason is that this server is installed at Claude Code's *user*
 * scope, so every Claude Code session on the machine sees these tools — including sessions with
 * nothing to do with vibing.nvim, which have no port to pass. See requireRpcPort in
 * tools/common.ts.
 */
const WRITE_TOOLS = [
  'nvim_set_buffer',
  'nvim_load_buffer',
  'nvim_set_cursor',
  'nvim_execute',
  'nvim_set_window_size',
  'nvim_focus_window',
  'nvim_win_set_buf',
  'nvim_win_open_file',
  'nvim_chat_send_message',
  'nvim_ask_user_question',
];

const schemaOf = (name: string) =>
  allTools.find((t) => t.name === name)?.inputSchema as
    { required?: string[]; properties?: Record<string, unknown> } | undefined;

describe('rpc_port policy', () => {
  it('requires rpc_port on every state-changing tool', () => {
    for (const name of WRITE_TOOLS) {
      const schema = schemaOf(name);
      expect(schema, `${name} is not registered`).toBeDefined();
      expect(schema?.required ?? [], `${name} must require rpc_port`).toContain('rpc_port');
    }
  });

  it('leaves rpc_port optional on every other tool that accepts it', () => {
    const readOnly = allTools
      .filter((t) => !WRITE_TOOLS.includes(t.name))
      .filter(
        (t) => (t.inputSchema as { properties?: Record<string, unknown> })?.properties?.rpc_port
      );

    expect(readOnly.length).toBeGreaterThan(0);
    for (const tool of readOnly) {
      const required = (tool.inputSchema as { required?: string[] })?.required ?? [];
      expect(required, `${tool.name} should not require rpc_port`).not.toContain('rpc_port');
    }
  });

  it('covers every registered tool by one rule or the other', () => {
    // Guards against a new tool being added without deciding which side it falls on.
    const undecided = allTools.filter(
      (t) =>
        !WRITE_TOOLS.includes(t.name) &&
        !(t.inputSchema as { properties?: Record<string, unknown> })?.properties?.rpc_port
    );

    // nvim_list_instances is the one tool that legitimately takes no port: reading the registry
    // is how you find out which ports exist in the first place.
    expect(undecided.map((t) => t.name)).toEqual(['nvim_list_instances']);
  });
});
