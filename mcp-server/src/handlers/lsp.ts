import { callNeovim } from '../rpc.js';

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

export async function handleDiagnostics(args: any) {
  const result = await callNeovim('diagnostics_get', { bufnr: args?.bufnr });
  return {
    content: [{ type: 'text', text: JSON.stringify(result, null, 2) }],
  };
}

export async function handleLspDocumentSymbols(args: any) {
  const result = await callNeovim('lsp_document_symbols', { bufnr: args?.bufnr });
  return {
    content: [{ type: 'text', text: JSON.stringify(result, null, 2) }],
  };
}

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
