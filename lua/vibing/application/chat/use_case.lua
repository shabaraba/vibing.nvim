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
local Git = require("vibing.core.utils.git")
local Fs = require("vibing.core.utils.fs")

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
    agent = config.adapter or "claude",
    mode = config.agent and config.agent.default_mode or "code",
    model = config.agent and config.agent.default_model or "sonnet",
    -- nil when default_effort is unset, which leaves the key out of the frontmatter entirely and
    -- lets the CLI apply its own default.
    effort = config.agent and config.agent.default_effort,
    permission_mode = config.permissions and config.permissions.mode or "acceptEdits",
    permissions_allow = config.permissions and config.permissions.allow or {},
    permissions_deny = config.permissions and config.permissions.deny or {},
  }
end

---新しいチャットセッションを作成
---@param opts? {working_dir?: string} working_dirはgitルートからの相対パス（省略時はcwdから算出）
---@return Vibing.ChatSession
function M.create_new(opts)
  local vibing = require("vibing")
  local config = vibing.get_config()

  -- チャットファイル自体は working_dir がどこであれ常に設定どおりの保存先に置く。
  -- worktreeの中に置くと `git worktree remove` で会話ごと消えてしまい、
  -- vibing-worktree-create（frontmatterだけ書き換える）とも挙動が食い違う
  --
  -- 空文字を明示的に弾く: Luaでは `""` がtruthyなので `opts.working_dir or ...` だけだと
  -- cwd由来の既定値にフォールバックせず `working_dir = ""` のまま進んでしまう。
  -- 呼び出し元（create_chat.lua）でも弾いているが、既定値の決定はこの関数の責務なので
  -- 呼び出し元頼みにしない
  local explicit = opts and opts.working_dir
  local working_dir = (explicit and explicit ~= "") and explicit or Git.get_relative_path(vim.fn.getcwd())

  local frontmatter = create_default_frontmatter(config)
  if working_dir then
    frontmatter.working_dir = working_dir
  end

  local session = ChatSession:new({
    frontmatter = frontmatter,
    working_dir = working_dir,
  })

  local save_path = FileManager.get_save_directory(config.chat)
  Fs.ensure_dir(save_path)
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

  local working_dir = Git.get_relative_path(normalized_dir)

  local frontmatter = create_default_frontmatter(config)
  if working_dir then
    frontmatter.working_dir = working_dir
  end

  local session = ChatSession:new({
    frontmatter = frontmatter,
    working_dir = working_dir,
  })

  local save_path = normalized_dir .. ".vibing/chat/"
  Fs.ensure_dir(save_path)
  local filename = FileManager.generate_unique_filename()
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

---Check if conversation has meaningful content
---@param conversation table[]
---@return boolean
local function has_conversation_content(conversation)
  for _, msg in ipairs(conversation) do
    if msg.content and vim.trim(msg.content) ~= "" then
      return true
    end
  end
  return false
end

---Maximum number of messages to include in summary (to avoid token limits)
local MAX_MESSAGES_FOR_SUMMARY = 50

---Format conversation for summary prompt with XML protection
---@param conversation table[]
---@return string
local function format_conversation_for_prompt(conversation)
  -- Trim to last N messages if conversation is too long
  local messages = conversation
  if #conversation > MAX_MESSAGES_FOR_SUMMARY then
    messages = {}
    local start_idx = #conversation - MAX_MESSAGES_FOR_SUMMARY + 1
    for i = start_idx, #conversation do
      table.insert(messages, conversation[i])
    end
  end

  local parts = {}
  for _, msg in ipairs(messages) do
    -- Wrap in XML tags to prevent prompt injection
    table.insert(parts, string.format("<message role=\"%s\">\n%s\n</message>", msg.role, msg.content))
  end
  return "<conversation>\n" .. table.concat(parts, "\n") .. "\n</conversation>"
end

---会話からサマリープロンプトを組み立てる
---
---`daily_summary` の `_build_summary_prompt` と同じ理由で切り出してある: プロンプトの組み立ては
---CLI を起動せずにテストできる唯一の接合部で、ここが `prompts/chat_summary.md` の変数名と
---合っているかを確かめる手段が他にない。`substitute_variables` は未知の `{{...}}` を黙って
---残すため、変数名を間違えると空の会話とリテラルの `{{conversation}}` がモデルに渡る。
---@param conversation table[]
---@return string|nil prompt
---@return string|nil error
function M._build_summary_prompt(conversation)
  local PromptLoader = require("vibing.core.utils.prompt_loader")
  return PromptLoader.load("chat_summary", {
    conversation = format_conversation_for_prompt(conversation),
  })
end

---チャット履歴からサマリーを生成してバッファに挿入
---@param chat_buffer Vibing.ChatBuffer
function M.generate_and_insert_summary(chat_buffer)
  local notify = require("vibing.core.utils.notify")

  if not chat_buffer or not chat_buffer.buf or not vim.api.nvim_buf_is_valid(chat_buffer.buf) then
    notify.error("No valid chat buffer")
    return
  end

  -- set_file_title と同じ理由でストリーミング中は断る。summary は `# Vibing Chat` の直下へ
  -- `nvim_buf_set_lines` で差し込むので、末尾に追記中のストリーミングと行番号で競合しうる。
  -- 加えて、途中状態の会話から要約を作ることにもなる。
  if chat_buffer:is_sending() then
    notify.warn("Cannot summarize while a response is streaming")
    return
  end

  local conversation = chat_buffer:extract_conversation()

  if #conversation == 0 or not has_conversation_content(conversation) then
    notify.warn("No conversation content to summarize")
    return
  end

  local vibing = require("vibing")
  local adapter = vibing.get_adapter()

  if not adapter then
    notify.error("No adapter configured")
    return
  end

  local full_prompt, err = M._build_summary_prompt(conversation)
  if err then
    notify.error("Failed to load summary prompt: " .. err)
    return
  end

  notify.info("Generating summary...")

  -- Capture buffer reference for async callback validation
  local buf = chat_buffer.buf

  adapter:stream(full_prompt, {}, function(_) end, function(response)
    -- Re-validate buffer in async callback (buffer may be deleted during AI processing)
    if not buf or not vim.api.nvim_buf_is_valid(buf) then
      notify.warn("Chat buffer was closed during summary generation")
      return
    end

    if not response then
      notify.error("No response received from AI")
      return
    end

    if response.error then
      notify.error(string.format("Summarization failed: %s", response.error))
      return
    end

    local summary = response.content
    if not summary or type(summary) ~= "string" or summary == "" then
      notify.warn("AI returned empty summary")
      return
    end

    local SummaryInserter = require("vibing.presentation.chat.modules.summary_inserter")
    if SummaryInserter.insert_or_update(buf, summary) then
      notify.info("Summary written to chat buffer")
    end
  end)
end

return M
