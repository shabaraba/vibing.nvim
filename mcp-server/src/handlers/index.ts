import * as buffer from './buffer.js';
import * as cursor from './cursor.js';
import * as execute from './execute.js';
import * as window from './window.js';
import * as lsp from './lsp.js';

export const handlers: Record<string, (args: any) => Promise<any>> = {
  // Buffer operations
  nvim_get_buffer: buffer.handleGetBuffer,
  nvim_set_buffer: buffer.handleSetBuffer,
  nvim_get_info: buffer.handleGetInfo,
  nvim_list_buffers: buffer.handleListBuffers,
  nvim_load_buffer: buffer.handleLoadBuffer,

  // Cursor operations
  nvim_get_cursor: cursor.handleGetCursor,
  nvim_set_cursor: cursor.handleSetCursor,
  nvim_get_visual_selection: cursor.handleGetVisualSelection,

  // Execute
  nvim_execute: execute.handleExecute,

  // Window operations
  nvim_list_windows: window.handleListWindows,
  nvim_get_window_info: window.handleGetWindowInfo,
  nvim_get_window_view: window.handleGetWindowView,
  nvim_list_tabpages: window.handleListTabpages,
  nvim_set_window_size: window.handleSetWindowSize,
  nvim_focus_window: window.handleFocusWindow,
  nvim_win_set_buf: window.handleWinSetBuf,
  nvim_win_open_file: window.handleWinOpenFile,

  // LSP operations
  nvim_lsp_definition: lsp.handleLspDefinition,
  nvim_lsp_references: lsp.handleLspReferences,
  nvim_lsp_hover: lsp.handleLspHover,
  nvim_diagnostics: lsp.handleDiagnostics,
  nvim_lsp_document_symbols: lsp.handleLspDocumentSymbols,
  nvim_lsp_type_definition: lsp.handleLspTypeDefinition,
  nvim_lsp_call_hierarchy_incoming: lsp.handleLspCallHierarchyIncoming,
  nvim_lsp_call_hierarchy_outgoing: lsp.handleLspCallHierarchyOutgoing,
};
