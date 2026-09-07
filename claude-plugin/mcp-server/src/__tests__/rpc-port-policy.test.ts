import { describe, it, expect } from 'vitest';
import { allTools } from '../tools/index.js';

/**
 * Reading the registry is how you find out which ports exist, so this one cannot take a port at
 * all. Every server-backed tool keeps an optional legacy override for manually launched clients.
 */
const PORTLESS_TOOLS = ['nvim_list_instances'];

const requiredOf = (tool: { inputSchema: unknown }) =>
  (tool.inputSchema as { required?: string[] })?.required ?? [];

const acceptsRpcPort = (tool: { inputSchema: unknown }) =>
  Boolean((tool.inputSchema as { properties?: Record<string, unknown> })?.properties?.rpc_port);

describe('rpc_port policy', () => {
  it('never requires the runtime-bound port from the model', () => {
    for (const tool of allTools) {
      expect(requiredOf(tool), `${tool.name} should not require rpc_port`).not.toContain(
        'rpc_port'
      );
    }
  });

  it('keeps an optional override on every server-backed tool', () => {
    for (const tool of allTools) {
      if (!PORTLESS_TOOLS.includes(tool.name)) {
        expect(acceptsRpcPort(tool), `${tool.name} should accept rpc_port`).toBe(true);
      }
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
