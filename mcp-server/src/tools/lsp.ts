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
      '[Neovim LSP] Jump to definition - Get definition location(s) from RUNNING Neovim LSP server for any loaded buffer (no need to display file)',
    inputSchema: {
      type: 'object' as const,
      properties: lspPositionSchema,
      required: ['line', 'col'],
    },
  },
  {
    name: 'nvim_lsp_references',
    description:
      '[Neovim LSP] Find references - Get all references from RUNNING Neovim LSP server for any loaded buffer (no need to display file)',
    inputSchema: {
      type: 'object' as const,
      properties: lspPositionSchema,
      required: ['line', 'col'],
    },
  },
  {
    name: 'nvim_lsp_hover',
    description:
      '[Neovim LSP] Hover info - Get type info and documentation from RUNNING Neovim LSP server for any loaded buffer (no need to display file)',
    inputSchema: {
      type: 'object' as const,
      properties: lspPositionSchema,
      required: ['line', 'col'],
    },
  },
  {
    name: 'nvim_diagnostics',
    description:
      '[Neovim LSP] Get diagnostics - Get errors/warnings from RUNNING Neovim LSP server for any loaded buffer (no need to display file)',
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
      '[Neovim LSP] Document symbols - Get all symbols from RUNNING Neovim LSP server for any loaded buffer (no need to display file)',
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
      '[Neovim LSP] Type definition - Get type definition location(s) from RUNNING Neovim LSP server for any loaded buffer (no need to display file)',
    inputSchema: {
      type: 'object' as const,
      properties: lspPositionSchema,
      required: ['line', 'col'],
    },
  },
  {
    name: 'nvim_lsp_call_hierarchy_incoming',
    description:
      '[Neovim LSP] Incoming calls - Get callers from RUNNING Neovim LSP server for any loaded buffer (no need to display file)',
    inputSchema: {
      type: 'object' as const,
      properties: lspPositionSchema,
      required: ['line', 'col'],
    },
  },
  {
    name: 'nvim_lsp_call_hierarchy_outgoing',
    description:
      '[Neovim LSP] Outgoing calls - Get callees from RUNNING Neovim LSP server for any loaded buffer (no need to display file)',
    inputSchema: {
      type: 'object' as const,
      properties: lspPositionSchema,
      required: ['line', 'col'],
    },
  },
];
