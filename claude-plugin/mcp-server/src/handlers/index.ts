import * as buffer from './buffer.js';
import * as cursor from './cursor.js';
import * as execute from './execute.js';
import * as window from './window.js';
import * as lsp from './lsp.js';
import * as instances from './instances.js';
import * as chat from './chat.js';
import * as highlight from './highlight.js';
import * as annotations from './annotations.js';
import * as qflist from './qflist.js';
import * as dap from './dap.js';

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

  // Instance management
  nvim_list_instances: instances.handleListInstances,

  // Chat operations
  nvim_chat_create: chat.handleChatCreate,
  nvim_chat_send_message: chat.handleChatSendMessage,
  nvim_ask_user_question: chat.handleAskUserQuestion,

  // Highlighting
  nvim_highlight_range: highlight.handleHighlightRange,
  nvim_clear_highlight: highlight.handleClearHighlight,

  // Annotations
  nvim_annotate: annotations.handleAnnotate,
  nvim_clear_annotations: annotations.handleClearAnnotations,
  // Quickfix
  nvim_set_qflist: qflist.handleSetQflist,

  // Debugger (nvim-dap)
  nvim_dap_get_state: dap.handleDapGetState,
  nvim_dap_get_stack_trace: dap.handleDapGetStackTrace,
  nvim_dap_get_variables: dap.handleDapGetVariables,
  nvim_dap_set_breakpoint: dap.handleDapSetBreakpoint,
  nvim_dap_evaluate: dap.handleDapEvaluate,
};
