import { callNeovim } from '../rpc.js';

/**
 * Fetches the LSP definition at the given buffer position from Neovim and returns it as pretty-printed JSON text.
 *
 * @param args - Object with required `line` and `col` (zero-based) and optional `bufnr` to target a specific buffer
 * @returns An object with a `content` array containing a single text node holding the pretty-printed JSON result
 * @throws Error if `line` or `col` are not provided
 */
export async function handleLspDefinition(args: any) {
  if (!args || args.line === undefined || args.col === undefined) {
    throw new Error('Missing required parameters: line and col');
  }
  const result = await callNeovim('lsp_definition', {
    bufnr: args.bufnr,
    line: args.line,
    col: args.col,
  });
  return {
    content: [{ type: 'text', text: JSON.stringify(result, null, 2) }],
  };
}

/**
 * Fetches LSP references for the specified buffer position and returns them as formatted JSON content.
 *
 * @param args - Argument object containing call parameters:
 *   - bufnr: optional buffer number to query
 *   - line: the line index of the position to query
 *   - col: the column index of the position to query
 * @returns An object with a `content` array containing a single text node whose `text` is the pretty-printed JSON representation of the references result.
 * @throws Error if `args` is missing or `args.line` or `args.col` are undefined (message: "Missing required parameters: line and col").
 */
export async function handleLspReferences(args: any) {
  if (!args || args.line === undefined || args.col === undefined) {
    throw new Error('Missing required parameters: line and col');
  }
  const result = await callNeovim('lsp_references', {
    bufnr: args.bufnr,
    line: args.line,
    col: args.col,
  });
  return {
    content: [{ type: 'text', text: JSON.stringify(result, null, 2) }],
  };
}

/**
 * Retrieve hover information from Neovim's LSP for the specified buffer position.
 *
 * @param args - Call arguments; must include `line` and `col`. May include `bufnr` to target a specific buffer.
 * @returns An object with a `content` array containing a single text node: the hover contents if available, otherwise the text "No hover information available".
 */
export async function handleLspHover(args: any) {
  if (!args || args.line === undefined || args.col === undefined) {
    throw new Error('Missing required parameters: line and col');
  }
  const result = await callNeovim('lsp_hover', {
    bufnr: args.bufnr,
    line: args.line,
    col: args.col,
  });
  return {
    content: [
      { type: 'text', text: result.contents || 'No hover information available' },
    ],
  };
}

/**
 * Retrieve diagnostics from Neovim for an optional buffer and return them as a text content node.
 *
 * @param args - Handler arguments; may include `bufnr` (buffer number) to scope diagnostics. If `bufnr` is omitted, diagnostics for the default context are requested.
 * @returns An object with a `content` array containing a single text node whose `text` is the pretty-printed JSON representation of the diagnostics result.
 */
export async function handleDiagnostics(args: any) {
  const result = await callNeovim('diagnostics_get', { bufnr: args?.bufnr });
  return {
    content: [{ type: 'text', text: JSON.stringify(result, null, 2) }],
  };
}

/**
 * Fetch document symbols from Neovim for an optional buffer and return them as pretty-printed JSON wrapped for UI consumption.
 *
 * @param args - Handler arguments; may include `bufnr` (the buffer number to query). If `bufnr` is not provided, the current buffer is used.
 * @returns An object with a `content` array containing a single text node whose `text` is the pretty-printed JSON representation of the document symbols.
 */
export async function handleLspDocumentSymbols(args: any) {
  const result = await callNeovim('lsp_document_symbols', { bufnr: args?.bufnr });
  return {
    content: [{ type: 'text', text: JSON.stringify(result, null, 2) }],
  };
}

/**
 * Request the LSP type definition for the given buffer position and return it as a UI-ready content payload.
 *
 * @param args - Request parameters; expected shape: `{ bufnr?: number, line: number, col: number }`
 * @returns An object with a `content` array containing a single text node whose `text` is the pretty-printed JSON representation of the LSP result.
 * @throws Error if `line` or `col` is missing from `args`.
 */
export async function handleLspTypeDefinition(args: any) {
  if (!args || args.line === undefined || args.col === undefined) {
    throw new Error('Missing required parameters: line and col');
  }
  const result = await callNeovim('lsp_type_definition', {
    bufnr: args.bufnr,
    line: args.line,
    col: args.col,
  });
  return {
    content: [{ type: 'text', text: JSON.stringify(result, null, 2) }],
  };
}

/**
 * Fetches incoming call-hierarchy entries for the symbol at the specified buffer position and returns them formatted for UI rendering.
 *
 * @param args - Invocation arguments. Must include `line` and `col`. May include `bufnr` to target a specific buffer.
 * @returns An object with a `content` array containing a single text node whose `text` is the pretty-printed JSON representation of the call-hierarchy result.
 * @throws Error when `line` or `col` is missing from `args`.
 */
export async function handleLspCallHierarchyIncoming(args: any) {
  if (!args || args.line === undefined || args.col === undefined) {
    throw new Error('Missing required parameters: line and col');
  }
  const result = await callNeovim('lsp_call_hierarchy_incoming', {
    bufnr: args.bufnr,
    line: args.line,
    col: args.col,
  });
  return {
    content: [{ type: 'text', text: JSON.stringify(result, null, 2) }],
  };
}

/**
 * Fetches the outgoing call hierarchy for the symbol at the provided buffer position via Neovim.
 *
 * @param args - Request parameters; must include `line` and `col` (numbers). May include `bufnr` to target a specific buffer.
 * @returns An object with a `content` array containing a single text node whose `text` is the pretty-printed JSON representation of the outgoing call hierarchy result.
 * @throws Error if `args` is missing or either `line` or `col` is undefined with message "Missing required parameters: line and col".
 */
export async function handleLspCallHierarchyOutgoing(args: any) {
  if (!args || args.line === undefined || args.col === undefined) {
    throw new Error('Missing required parameters: line and col');
  }
  const result = await callNeovim('lsp_call_hierarchy_outgoing', {
    bufnr: args.bufnr,
    line: args.line,
    col: args.col,
  });
  return {
    content: [{ type: 'text', text: JSON.stringify(result, null, 2) }],
  };
}
