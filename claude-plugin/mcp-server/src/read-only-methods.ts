/**
 * The RPC methods that only look at Neovim.
 *
 * `rpc.ts` guesses an instance from the registry for these and refuses to for anything else.
 * Reads are safe to guess: the worst case is answering about the wrong buffer. A call that
 * changes state is not, because this server can also be registered at Claude Code's *user*
 * scope, where an ordinary session that has nothing to do with vibing.nvim sees these tools with
 * no `VIBING_NVIM_RPC_PORT` in its environment. Guessing there would hand it `nvim_execute`,
 * `nvim_set_buffer` and `nvim_chat_send_message` against whichever editor the user has open.
 *
 * **The list is an allowlist, so a new method is a writer until it is added here.** A method name
 * that says nothing about its behaviour has to count as one; the failure of the opposite shape is
 * silent, since a missing entry only shows up on a machine running exactly one Neovim.
 */
export const READ_ONLY_METHODS = new Set([
  'buf_get_lines',
  'chat_conflicts',
  'diagnostics_get',
  'get_current_file',
  'get_cursor_position',
  'get_visual_selection',
  'get_window_info',
  'get_window_view',
  'list_buffers',
  'list_chats',
  'list_tabpages',
  'list_windows',
  'job_list',
  'job_status',
  'job_wait',
  'lsp_call_hierarchy_incoming',
  'lsp_call_hierarchy_outgoing',
  'lsp_definition',
  'lsp_document_symbols',
  'lsp_hover',
  'lsp_references',
  'lsp_type_definition',
]);
