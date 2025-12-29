export interface ToolDefinition {
  name: string;
  description: string;
  inputSchema: {
    type: 'object';
    properties: Record<string, unknown>;
    required?: string[];
  };
  handler: (params: Record<string, unknown>) => Promise<unknown>;
}

export interface ToolRegistry {
  register(tool: ToolDefinition): void;
  get(name: string): ToolDefinition | undefined;
  list(): string[];
  getAll(): ToolDefinition[];
}

export function createToolRegistry(): ToolRegistry {
  const tools = new Map<string, ToolDefinition>();

  const defaultTools: ToolDefinition[] = [
    {
      name: 'nvim_get_buffer',
      description: 'Get current buffer content',
      inputSchema: {
        type: 'object',
        properties: {
          bufnr: {
            type: 'number',
            description: 'Buffer number (0 for current buffer)',
          },
        },
      },
      handler: async (params) => {
        return { content: '', lines: 0 };
      },
    },
    {
      name: 'nvim_set_buffer',
      description: 'Replace buffer content',
      inputSchema: {
        type: 'object',
        properties: {
          bufnr: {
            type: 'number',
            description: 'Buffer number (0 for current buffer)',
          },
          lines: {
            type: 'string',
            description: 'New content (newline-separated)',
          },
        },
        required: ['lines'],
      },
      handler: async (params) => {
        return { success: true };
      },
    },
    {
      name: 'nvim_get_info',
      description: 'Get current file information',
      inputSchema: {
        type: 'object',
        properties: {},
      },
      handler: async () => {
        return { filepath: '', bufnr: 0, filetype: '' };
      },
    },
    {
      name: 'nvim_list_buffers',
      description: 'List all loaded buffers',
      inputSchema: {
        type: 'object',
        properties: {},
      },
      handler: async () => {
        return { buffers: [] };
      },
    },
    {
      name: 'nvim_get_cursor',
      description: 'Get cursor position',
      inputSchema: {
        type: 'object',
        properties: {},
      },
      handler: async () => {
        return { line: 1, col: 0 };
      },
    },
    {
      name: 'nvim_set_cursor',
      description: 'Set cursor position',
      inputSchema: {
        type: 'object',
        properties: {
          line: { type: 'number', description: 'Line number (1-indexed)' },
          col: { type: 'number', description: 'Column number (0-indexed)' },
        },
        required: ['line'],
      },
      handler: async (params) => {
        return { success: true };
      },
    },
    {
      name: 'nvim_get_visual_selection',
      description: 'Get visual selection range and content',
      inputSchema: {
        type: 'object',
        properties: {},
      },
      handler: async () => {
        return { start: { line: 1, col: 0 }, end: { line: 1, col: 0 }, content: '' };
      },
    },
    {
      name: 'nvim_execute',
      description: 'Execute Neovim command',
      inputSchema: {
        type: 'object',
        properties: {
          command: { type: 'string', description: 'Neovim command to execute' },
        },
        required: ['command'],
      },
      handler: async (params) => {
        return { success: true, output: '' };
      },
    },
    {
      name: 'nvim_list_windows',
      description: 'List all windows with their properties',
      inputSchema: {
        type: 'object',
        properties: {},
      },
      handler: async () => {
        return { windows: [] };
      },
    },
    {
      name: 'nvim_lsp_definition',
      description: 'Get definition location(s) of symbol',
      inputSchema: {
        type: 'object',
        properties: {
          bufnr: { type: 'number', description: 'Buffer number (0 for current)' },
          line: { type: 'number', description: 'Line number (1-indexed)' },
          col: { type: 'number', description: 'Column number (0-indexed)' },
        },
        required: ['line', 'col'],
      },
      handler: async (params) => {
        return { locations: [] };
      },
    },
    {
      name: 'nvim_lsp_references',
      description: 'Get all references to symbol',
      inputSchema: {
        type: 'object',
        properties: {
          bufnr: { type: 'number', description: 'Buffer number (0 for current)' },
          line: { type: 'number', description: 'Line number (1-indexed)' },
          col: { type: 'number', description: 'Column number (0-indexed)' },
        },
        required: ['line', 'col'],
      },
      handler: async (params) => {
        return { references: [] };
      },
    },
    {
      name: 'nvim_diagnostics',
      description: 'Get diagnostics (errors, warnings)',
      inputSchema: {
        type: 'object',
        properties: {
          bufnr: { type: 'number', description: 'Buffer number (0 for current)' },
        },
      },
      handler: async (params) => {
        return { diagnostics: [] };
      },
    },
  ];

  for (const tool of defaultTools) {
    tools.set(tool.name, tool);
  }

  return {
    register(tool: ToolDefinition): void {
      tools.set(tool.name, tool);
    },

    get(name: string): ToolDefinition | undefined {
      return tools.get(name);
    },

    list(): string[] {
      return Array.from(tools.keys());
    },

    getAll(): ToolDefinition[] {
      return Array.from(tools.values());
    },
  };
}
