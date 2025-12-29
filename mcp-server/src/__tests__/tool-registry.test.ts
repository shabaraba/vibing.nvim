import { describe, it, expect, beforeEach } from 'vitest';
import { ToolRegistry, createToolRegistry } from '../registry/tool-registry';

describe('ToolRegistry (UT-MCP-003)', () => {
  let registry: ToolRegistry;

  beforeEach(() => {
    registry = createToolRegistry();
  });

  describe('registration', () => {
    it('should register a tool', () => {
      const tool = registry.get('nvim_get_buffer');
      expect(tool).toBeDefined();
      expect(tool?.name).toBe('nvim_get_buffer');
    });

    it('should return undefined for unregistered tool', () => {
      const tool = registry.get('non_existent_tool');
      expect(tool).toBeUndefined();
    });
  });

  describe('listTools', () => {
    it('should list all registered tools', () => {
      const tools = registry.list();
      expect(Array.isArray(tools)).toBe(true);
      expect(tools.length).toBeGreaterThan(0);
      expect(tools).toContain('nvim_get_buffer');
      expect(tools).toContain('nvim_set_buffer');
    });
  });

  describe('getDescription', () => {
    it('should return tool description', () => {
      const tool = registry.get('nvim_get_buffer');
      expect(tool?.description).toBeDefined();
      expect(typeof tool?.description).toBe('string');
    });
  });

  describe('tool handler', () => {
    it('should have handler function for each tool', () => {
      const tools = registry.list();
      for (const toolName of tools) {
        const tool = registry.get(toolName);
        expect(tool?.handler).toBeDefined();
        expect(typeof tool?.handler).toBe('function');
      }
    });
  });
});
