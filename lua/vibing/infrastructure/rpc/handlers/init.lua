local M = {}

-- Load all handlers
local buffer = require("vibing.infrastructure.rpc.handlers.buffer")
local cursor = require("vibing.infrastructure.rpc.handlers.cursor")
local window = require("vibing.infrastructure.rpc.handlers.window")
local lsp = require("vibing.infrastructure.rpc.handlers.lsp")
local execute = require("vibing.infrastructure.rpc.handlers.execute")
local message = require("vibing.infrastructure.rpc.handlers.message")
local squad = require("vibing.infrastructure.rpc.handlers.squad")
local mention = require("vibing.infrastructure.mention.rpc_handlers")

-- Export all handlers
M.buf_get_lines = buffer.buf_get_lines
M.buf_set_lines = buffer.buf_set_lines
M.get_current_file = buffer.get_current_file
M.list_buffers = buffer.list_buffers
M.load_buffer = buffer.load_buffer

M.get_cursor_position = cursor.get_cursor_position
M.set_cursor_position = cursor.set_cursor_position
M.get_visual_selection = cursor.get_visual_selection

M.list_windows = window.list_windows
M.get_window_info = window.get_window_info
M.get_window_view = window.get_window_view
M.list_tabpages = window.list_tabpages
M.set_window_width = window.set_window_width
M.set_window_height = window.set_window_height
M.focus_window = window.focus_window
M.win_set_buf = window.win_set_buf
M.win_open_file = window.win_open_file

M.lsp_definition = lsp.lsp_definition
M.lsp_references = lsp.lsp_references
M.lsp_hover = lsp.lsp_hover
M.diagnostics_get = lsp.diagnostics_get
M.lsp_document_symbols = lsp.lsp_document_symbols
M.lsp_type_definition = lsp.lsp_type_definition
M.lsp_call_hierarchy_incoming = lsp.lsp_call_hierarchy_incoming
M.lsp_call_hierarchy_outgoing = lsp.lsp_call_hierarchy_outgoing

M.execute = execute.execute

M.send_message = message.send_message

M.get_squad_info = squad.get_squad_info
M.list_squads = squad.list_squads
M.find_squad_buffer = squad.find_squad_buffer

M.get_mention_info = mention.get_mention_info
M.mark_mention_processed = mention.mark_mention_processed
M.mark_all_mentions_processed = mention.mark_all_mentions_processed
M.record_mention = mention.record_mention

return M
