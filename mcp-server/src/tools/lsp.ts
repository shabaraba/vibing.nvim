const lspPositionSchema = {
  bufnr: {
    type: 'number' as const,
    description: 'Buffer number (0 for current)',
  },
  line: {
    type: 'number' as const,
    description: 'Line number (1-indexed)',
  },
  col: {
    type: 'number' as const,
    description: 'Column number (0-indexed)',
  },
};

export const lspTools = [
  {
    name: 'nvim_lsp_definition',
    description:
      '[Neovim LSP] Jump to definition - Works with ANY loaded buffer. Background workflow: nvim_execute("edit file.ts") → nvim_execute("bp") → use this tool with bufnr',
    inputSchema: {
      type: 'object' as const,
      properties: lspPositionSchema,
      required: ['line', 'col'],
    },
  },
  {
    name: 'nvim_lsp_references',
    description:
      '[Neovim LSP] Find references - Works with ANY loaded buffer. Background workflow: nvim_execute("edit file.ts") → nvim_execute("bp") → use this tool with bufnr',
    inputSchema: {
      type: 'object' as const,
      properties: lspPositionSchema,
      required: ['line', 'col'],
    },
  },
  {
    name: 'nvim_lsp_hover',
    description:
      '[Neovim LSP] Hover info - Works with ANY loaded buffer. Background workflow: nvim_execute("edit file.ts") → nvim_execute("bp") → use this tool with bufnr',
    inputSchema: {
      type: 'object' as const,
      properties: lspPositionSchema,
      required: ['line', 'col'],
    },
  },
  {
    name: 'nvim_diagnostics',
    description:
      '[Neovim LSP] Get diagnostics - Works with ANY loaded buffer. Background workflow: nvim_execute("edit file.ts") → nvim_execute("bp") → use this tool with bufnr',
    inputSchema: {
      type: 'object' as const,
      properties: {
        bufnr: {
          type: 'number' as const,
          description: 'Buffer number (0 for current)',
        },
      },
    },
  },
  {
    name: 'nvim_lsp_document_symbols',
    description:
      '[Neovim LSP] Document symbols - Works with ANY loaded buffer. Background workflow: nvim_execute("edit file.ts") → nvim_execute("bp") → use this tool with bufnr',
    inputSchema: {
      type: 'object' as const,
      properties: {
        bufnr: {
          type: 'number' as const,
          description: 'Buffer number (0 for current)',
        },
      },
    },
  },
  {
    name: 'nvim_lsp_type_definition',
    description:
      '[Neovim LSP] Type definition - Works with ANY loaded buffer. Background workflow: nvim_execute("edit file.ts") → nvim_execute("bp") → use this tool with bufnr',
    inputSchema: {
      type: 'object' as const,
      properties: lspPositionSchema,
      required: ['line', 'col'],
    },
  },
  {
    name: 'nvim_lsp_call_hierarchy_incoming',
    description:
      '[Neovim LSP] Incoming calls - Works with ANY loaded buffer. Background workflow: nvim_execute("edit file.ts") → nvim_execute("bp") → use this tool with bufnr',
    inputSchema: {
      type: 'object' as const,
      properties: lspPositionSchema,
      required: ['line', 'col'],
    },
  },
  {
    name: 'nvim_lsp_call_hierarchy_outgoing',
    description:
      '[Neovim LSP] Outgoing calls - Works with ANY loaded buffer. Background workflow: nvim_execute("edit file.ts") → nvim_execute("bp") → use this tool with bufnr',
    inputSchema: {
      type: 'object' as const,
      properties: lspPositionSchema,
      required: ['line', 'col'],
    },
  },
];
