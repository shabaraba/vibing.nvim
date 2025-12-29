---@class Vibing.Application.SendMessageUseCase
---メッセージ送信ユースケース
local M = {}

local Context = require("vibing.context")
local Formatter = require("vibing.context.formatter")
local StatusManager = require("vibing.status_manager")
local BufferReload = require("vibing.utils.buffer_reload")
local BufferIdentifier = require("vibing.utils.buffer_identifier")

---メッセージを送信
---@param adapter table アダプター
---@param chat_buffer table チャットバッファ
---@param message string メッセージ
---@param config table 設定
function M.execute(adapter, chat_buffer, message, config)
  if not adapter then
    require("vibing.utils.notify").error("No adapter configured", "Chat")
    return
  end

  local contexts = Context.get_all(config.chat.auto_context)
  local formatted_prompt = Formatter.format_prompt(message, contexts, config.chat.context_position)

  local conversation = chat_buffer:extract_conversation()
  if #conversation == 0 then
    chat_buffer:update_filename_from_message(message)
  end

  chat_buffer:start_response()

  local frontmatter = chat_buffer:parse_frontmatter()
  local saved_contents = M._save_buffer_contents()

  local status_mgr = StatusManager:new(config.status)
  local modified_files = {}
  local file_tools = { Edit = true, Write = true, nvim_set_buffer = true }

  local opts = {
    streaming = true,
    action_type = "chat",
    status_manager = status_mgr,
    mode = frontmatter.mode,
    model = frontmatter.model,
    permissions_allow = frontmatter.permissions_allow,
    permissions_deny = frontmatter.permissions_deny,
    permissions_ask = frontmatter.permissions_ask,
    permission_mode = frontmatter.permission_mode,
    on_tool_use = function(tool, file_path)
      if file_tools[tool] and file_path then
        if not vim.tbl_contains(modified_files, file_path) then
          table.insert(modified_files, file_path)
        end
      end
    end,
  }

  if adapter:supports("session") then
    adapter:cleanup_stale_sessions()
    opts._session_id = chat_buffer:get_session_id()
    opts._session_id_explicit = true
  end

  if adapter:supports("streaming") then
    local handle_id = adapter:stream(formatted_prompt, opts, function(chunk)
      vim.schedule(function()
        chat_buffer:append_chunk(chunk)
      end)
    end, function(response)
      vim.schedule(function()
        M._handle_response(response, status_mgr, chat_buffer, modified_files, saved_contents, adapter)
      end)
    end)
  else
    local response = adapter:execute(formatted_prompt, opts)
    M._handle_response(response, status_mgr, chat_buffer, modified_files, saved_contents, adapter)
  end
end

---バッファの内容を保存
---@return table<string, string[]>
function M._save_buffer_contents()
  local saved = {}
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) then
      local file_path = vim.api.nvim_buf_get_name(buf)
      local content = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

      if file_path ~= "" then
        saved[vim.fn.fnamemodify(file_path, ":p")] = content
      else
        saved[BufferIdentifier.create_identifier(buf)] = content
      end
    end
  end
  return saved
end

---レスポンスを処理
function M._handle_response(response, status_mgr, chat_buffer, modified_files, saved_contents, adapter)
  if response.error then
    status_mgr:set_error(response.error)
    chat_buffer:append_chunk("\n\n**Error:** " .. response.error)
  else
    status_mgr:set_done(modified_files)
  end

  if #modified_files > 0 then
    BufferReload.reload_files(modified_files)
    chat_buffer:append_chunk("\n\n### Modified Files\n\n")
    for _, file_path in ipairs(modified_files) do
      chat_buffer:append_chunk(vim.fn.fnamemodify(file_path, ":.") .. "\n")
    end
    chat_buffer:set_last_modified_files(modified_files, saved_contents)
  end

  if adapter:supports("session") and response._handle_id then
    local new_session = adapter:get_session_id(response._handle_id)
    if new_session and new_session ~= chat_buffer:get_session_id() then
      chat_buffer:update_session_id(new_session)
    end
  end

  chat_buffer:add_user_section()
end

return M
