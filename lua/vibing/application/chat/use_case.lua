---@class Vibing.Application.ChatUseCase
---チャット機能のアプリケーション層Use Case
---ビジネスロジックのみを担当し、Presentation層に依存しない
---
---NOTE: セッション状態はChatBufferインスタンスで管理されるべきであり、
---このモジュールはセッション作成のファクトリとしてのみ機能する。
---グローバル状態 M._current_session は廃止予定。
local M = {}

local ChatSession = require("vibing.domain.chat.session")
local FileManager = require("vibing.presentation.chat.modules.file_manager")

---@deprecated このグローバル状態は複数チャットウィンドウで問題を起こすため廃止予定
---セッションはChatBufferインスタンスの.sessionプロパティを使用すること
---@type Vibing.ChatSession?
M._current_session = nil

---デフォルトのフロントマターを生成
---@param config table vibing設定
---@return table frontmatter
local function create_default_frontmatter(config)
  return {
    ["vibing.nvim"] = true,
    created_at = os.date("%Y-%m-%dT%H:%M:%S"),
    mode = config.agent and config.agent.default_mode or "code",
    model = config.agent and config.agent.default_model or "sonnet",
    permission_mode = config.permissions and config.permissions.mode or "acceptEdits",
    permissions_allow = config.permissions and config.permissions.allow or {},
    permissions_deny = config.permissions and config.permissions.deny or {},
  }
end

---新しいチャットセッションを作成
---@return Vibing.ChatSession
function M.create_new()
  local vibing = require("vibing")
  local config = vibing.get_config()

  local session = ChatSession:new({
    frontmatter = create_default_frontmatter(config),
  })

  local save_path = FileManager.get_save_directory(config.chat)
  vim.fn.mkdir(save_path, "p")
  local filename = FileManager.generate_unique_filename()
  session:set_file_path(save_path .. filename)

  return session
end

---指定されたディレクトリで新しいチャットセッションを作成
---@param directory string 作業ディレクトリのパス
---@return Vibing.ChatSession
function M.create_new_in_directory(directory)
  local vibing = require("vibing")
  local config = vibing.get_config()

  local normalized_dir = vim.fn.fnamemodify(directory, ":p")
  if not normalized_dir:match("/$") then
    normalized_dir = normalized_dir .. "/"
  end
  local cwd = normalized_dir:gsub("/$", "")

  local session = ChatSession:new({
    frontmatter = create_default_frontmatter(config),
    cwd = cwd,
  })

  local save_path = normalized_dir .. ".vibing/chat/"
  vim.fn.mkdir(save_path, "p")
  local filename = FileManager.generate_unique_filename()
  session:set_file_path(save_path .. filename)

  return session
end

---worktree用の新しいチャットセッションを作成
---チャットファイルはメインリポジトリの.vibing/worktrees/<branch>/に保存
---@param worktree_path string worktreeのパス
---@param branch_name string ブランチ名
---@return Vibing.ChatSession
function M.create_new_for_worktree(worktree_path, branch_name)
  local vibing = require("vibing")
  local config = vibing.get_config()

  local normalized_worktree = vim.fn.fnamemodify(worktree_path, ":p"):gsub("/$", "")

  local git_root = vim.fn.systemlist("git rev-parse --show-toplevel")[1]
  if vim.v.shell_error ~= 0 then
    require("vibing.core.utils.notify").error("Failed to get git root", "Chat")
    return M.create_new()
  end

  local session = ChatSession:new({
    frontmatter = create_default_frontmatter(config),
    cwd = normalized_worktree,
  })

  local save_path = git_root .. "/.vibing/worktrees/" .. branch_name .. "/"
  vim.fn.mkdir(save_path, "p")
  local filename = os.date("chat-%Y%m%d-%H%M%S.vibing")
  session:set_file_path(save_path .. filename)

  return session
end

---既存のチャットファイルを開く
---@param file_path string ファイルパス
---@return Vibing.ChatSession?
function M.open_file(file_path)
  local session = ChatSession.load_from_file(file_path)
  return session
end

---@deprecated この関数はグローバル状態に依存するため廃止予定
---代わりにview.get_current()でChatBufferを取得し、そのセッションを使用すること
---@return Vibing.ChatSession
function M.get_or_create_session()
  if M._current_session then
    return M._current_session
  end
  return M.create_new()
end

---既存バッファにアタッチ（:eで開いたファイル用）
---@param bufnr number バッファ番号
---@param file_path string ファイルパス
function M.attach_to_buffer(bufnr, file_path)
  local view = require("vibing.presentation.chat.view")
  view.attach_to_buffer(bufnr, file_path)
end

---チャット履歴からサマリーを生成してバッファに挿入
---@param chat_buffer Vibing.ChatBuffer
function M.generate_and_insert_summary(chat_buffer)
  local notify = require("vibing.core.utils.notify")

  if not chat_buffer or not chat_buffer.buf or not vim.api.nvim_buf_is_valid(chat_buffer.buf) then
    notify.error("No valid chat buffer")
    return
  end

  local conversation = chat_buffer:extract_conversation()

  if #conversation == 0 then
    notify.warn("No conversation to summarize")
    return
  end

  local has_content = false
  for _, msg in ipairs(conversation) do
    if msg.content and vim.trim(msg.content) ~= "" then
      has_content = true
      break
    end
  end

  if not has_content then
    notify.warn("No conversation content to summarize")
    return
  end

  local summary_prompt = [[
Please analyze the conversation above and generate a summary in the following EXACT format (in Japanese):

## summary

### やったこと
- (bullet points of what was accomplished)

### 直面した課題と解決策
- (bullet points of challenges faced and how they were resolved)

### 関連issueやPR
- (bullet points of related issues/PRs mentioned, or "なし" if none were mentioned)

IMPORTANT: Output ONLY the summary section starting with "## summary". Do not include any other text or explanation.
]]

  local conversation_text = {}
  for _, msg in ipairs(conversation) do
    table.insert(conversation_text, string.format("[%s]: %s", msg.role, msg.content))
  end

  local full_prompt = table.concat(conversation_text, "\n\n") .. "\n\n" .. summary_prompt

  local vibing = require("vibing")
  local adapter = vibing.get_adapter()

  if not adapter then
    notify.error("No adapter configured")
    return
  end

  notify.info("Generating summary...")

  adapter:stream(full_prompt, {}, function(_) end, function(response)
    if not response then
      notify.error("No response received from AI")
      return
    end

    if response.error then
      notify.error(string.format("Summarization failed: %s", response.error))
      return
    end

    local summary = response.content
    if summary and type(summary) == "string" and summary ~= "" then
      local SummaryInserter = require("vibing.presentation.chat.modules.summary_inserter")
      local success = SummaryInserter.insert_or_update(chat_buffer.buf, summary)
      if success then
        notify.info("Summary written to chat buffer")
      end
    else
      notify.warn("AI returned empty summary")
    end
  end)
end

return M
