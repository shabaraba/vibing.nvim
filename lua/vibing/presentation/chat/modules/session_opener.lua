---@class Vibing.Presentation.Chat.SessionOpener
---見つけた CLI セッションを、新しいチャットとして開く2通りの道。
---
---- resume: `session_id`・`agent`・`working_dir` を入れたチャットで、元のセッションをそのまま続ける。
---  セッション ID は CLI ごとのもので、`working_dir` は git ルートの内側しか持てないので、
---  同じ CLI でこのリポジトリの中のセッションに限る
---- 引き継ぎ: 新しいチャットの未送信欄に「そのセッションを読んで続きをやる」依頼を下書きする。
---  読むのは `nvim_session_read` なので、CLI もリポジトリも問わない
local M = {}

local notify = require("vibing.core.utils.notify")
local FileBuffer = require("vibing.core.utils.file_buffer")
local Git = require("vibing.core.utils.git")

---@param result Vibing.Session.Search.Result
---@return string? working_dir git ルートからの相対パス
---@return string? reason resume できない理由
function M.resume_target(result)
  local adapter = require("vibing").get_config().adapter or "claude"
  if result.backend ~= adapter then
    return nil, string.format("it was started on %s, and new chats here run on %s", result.backend, adapter)
  end
  if not result.cwd or vim.fn.isdirectory(result.cwd) ~= 1 then
    return nil, "its working directory is unknown or gone"
  end
  local working_dir = Git.get_relative_path(FileBuffer.canonical(result.cwd))
  if not working_dir then
    return nil, string.format("it ran in %s, outside this repository", result.cwd)
  end
  return working_dir, nil
end

---@param result Vibing.Session.Search.Result
---@return boolean opened
function M.resume(result)
  local working_dir, reason = M.resume_target(result)
  if not working_dir then
    notify.warn(string.format("Cannot resume this session: %s. Hand it off instead (<C-h>).", reason))
    return false
  end

  local session = require("vibing.application.chat.use_case").create_new({ working_dir = working_dir })
  session:update_session_id(result.session_id)
  session:update_frontmatter("agent", result.backend)
  require("vibing.presentation.chat.view").render(session)
  return true
end

---@param result Vibing.Session.Search.Result
---@return string[]
function M.handoff_lines(result)
  return {
    string.format(
      "Read the %s session %s%s with nvim_session_read, summarize the decisions made and the work "
        .. "that remains, then continue that work here.",
      result.backend,
      result.session_id,
      result.cwd and (" (cwd: " .. result.cwd .. ")") or ""
    ),
  }
end

---@param result Vibing.Session.Search.Result
---@return boolean opened
function M.handoff(result)
  local session = require("vibing.application.chat.use_case").create_new()
  local chat_buf = require("vibing.presentation.chat.view").render(session)
  local buf = chat_buf and chat_buf.buf
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return false
  end

  vim.api.nvim_buf_set_lines(buf, -1, -1, false, M.handoff_lines(result))
  local win = vim.fn.bufwinid(buf)
  if win ~= -1 then
    vim.api.nvim_win_set_cursor(win, { vim.api.nvim_buf_line_count(buf), 0 })
  end
  return true
end

return M
