import { withRpcPort } from './common.js';

/**
 * Every LSP query is one tool, `method` choosing which. They were eight tools with
 * near-identical schemas, which cost ~4.8KB of tool definitions on every request for what one
 * enum says. All of them are reads, which is what makes merging them safe: a permission rule
 * naming this tool cannot be asked to tell a harmless call from a harmful one. The DAP tools are
 * merged only as far as that holds (`dap.ts`).
 */
export const LSP_POSITION_METHODS = [
  'definition',
  'references',
  'hover',
  'type_definition',
  'call_hierarchy_incoming',
  'call_hierarchy_outgoing',
] as const;
export const LSP_BUFFER_METHODS = ['document_symbols', 'diagnostics'] as const;

export const lspTools = [
  {
    name: 'nvim_lsp',
    description:
      '[Neovim LSP] Query the live LSP of the running Neovim. Works with ANY loaded buffer — load ' +
      'it first with nvim_load_buffer if it is not already open. `line` and `col` are required ' +
      'for every method except document_symbols and diagnostics.',
    inputSchema: {
      type: 'object' as const,
      properties: withRpcPort({
        method: {
          type: 'string' as const,
          enum: [...LSP_POSITION_METHODS, ...LSP_BUFFER_METHODS],
        },
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
      }),
      required: ['method'],
    },
  },
];
