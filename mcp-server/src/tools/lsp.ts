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
    description: 'Get definition location(s) of symbol at cursor position',
    inputSchema: {
      type: 'object' as const,
      properties: lspPositionSchema,
      required: ['line', 'col'],
    },
  },
  {
    name: 'nvim_lsp_references',
    description: 'Get all references to symbol at cursor position',
    inputSchema: {
      type: 'object' as const,
      properties: lspPositionSchema,
      required: ['line', 'col'],
    },
  },
  {
    name: 'nvim_lsp_hover',
    description: 'Get hover information (type, documentation) for symbol at cursor',
    inputSchema: {
      type: 'object' as const,
      properties: lspPositionSchema,
      required: ['line', 'col'],
    },
  },
  {
    name: 'nvim_diagnostics',
    description: 'Get diagnostics (errors, warnings) for buffer',
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
    description: 'Get all symbols in the document',
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
    description: 'Get type definition location(s) of symbol at cursor',
    inputSchema: {
      type: 'object' as const,
      properties: lspPositionSchema,
      required: ['line', 'col'],
    },
  },
  {
    name: 'nvim_lsp_call_hierarchy_incoming',
    description: 'Get incoming calls (callers) for symbol at cursor',
    inputSchema: {
      type: 'object' as const,
      properties: lspPositionSchema,
      required: ['line', 'col'],
    },
  },
  {
    name: 'nvim_lsp_call_hierarchy_outgoing',
    description: 'Get outgoing calls (callees) for symbol at cursor',
    inputSchema: {
      type: 'object' as const,
      properties: lspPositionSchema,
      required: ['line', 'col'],
    },
  },
];
