local notify = require("vibing.core.utils.notify")
local title_generator = require("vibing.core.utils.title_generator")
local filename_util = require("vibing.core.utils.filename")
local FileManager = require("vibing.presentation.chat.modules.file_manager")
local SyncManager = require("vibing.application.link.sync_manager")
local DailySummaryScanner = require("vibing.infrastructure.link.daily_summary_scanner")
local ForkedChatScanner = require("vibing.infrastructure.link.forked_chat_scanner")
local OrchestrationChatScanner = require("vibing.infrastructure.link.orchestration_chat_scanner")
local SummaryInserter = require("vibing.presentation.chat.modules.summary_inserter")
local Fs = require("vibing.core.utils.fs")

---@param dir string
---@return string
local function ensure_trailing_slash(dir)
  if dir:sub(-1) ~= "/" then
    return dir .. "/"
  end
  return dir
end

---@param dir string
---@param base_filename string
---@return string
local function get_unique_file_path(dir, base_filename)
  dir = ensure_trailing_slash(dir)
  local new_path = dir .. base_filename

  if vim.fn.filereadable(new_path) == 0 then
    return new_path
  end

  local name_without_ext = base_filename:gsub("%.md$", "")
  local counter = 1

  while vim.fn.filereadable(new_path) == 1 do
    new_path = dir .. string.format("%s_%d.md", name_without_ext, counter)
    counter = counter + 1
  end

  return new_path
end

---会話から最初のユーザーメッセージの1行目を取り出す（タイトル生成フォールバック用）
---@param conversation {role: string, content: string}[]
---@return string? first_line
local function first_user_line(conversation)
  for _, msg in ipairs(conversation) do
    if msg.role == "user" and msg.content and msg.content ~= "" then
      return msg.content:match("^([^\n]+)") or msg.content
    end
  end
  return nil
end

---@param buf number
---@return boolean ok
---@return string? error
local function save_buffer(buf)
  local ok, err = pcall(function()
    vim.api.nvim_buf_call(buf, function()
      vim.cmd.write({ bang = true })  -- Force overwrite with :write!
    end)
  end)
  return ok, err
end

---@param _ string[]
---@param chat_buffer Vibing.ChatBuffer
---@return boolean
return function(_, chat_buffer)
  if not chat_buffer or not chat_buffer.buf or not vim.api.nvim_buf_is_valid(chat_buffer.buf) then
    notify.error("No valid chat buffer")
    return false
  end

  -- ストリーミング中はバッファがまだ確定していない。会話は途中状態なのでそこからタイトルを
  -- 作ることになるし、リネームのための `:write!` が応答の追記と競合する。
  -- （#475 当時の理由だった「同一 session_id への resume 競合」は、タイトル生成が resume を
  -- やめた時点で消えている。残っているのは上の2つ。）
  if chat_buffer:is_sending() then
    notify.warn("Cannot generate title while a response is streaming")
    return false
  end

  local conversation = chat_buffer:extract_conversation()
  if #conversation == 0 then
    notify.warn("No conversation to generate title from")
    return false
  end

  -- `:VibingSummarize` が書いた `## summary` があれば、抜粋ではなくそちらを入力にする。
  -- summary は既に「会話全体で何をしたか」に圧縮されているので、長い会話でも主題を外しにくく、
  -- 送るテキストも短い。無ければ従来どおり抜粋にフォールバックする（後方互換）。
  local summary = SummaryInserter.extract(chat_buffer.buf)

  local old_file_path = chat_buffer.file_path
  local vibing = require("vibing")
  local config = vibing.get_config()
  local save_dir = FileManager.get_save_directory(config.chat)
  local is_existing_file = old_file_path and vim.fn.filereadable(old_file_path) == 1

  -- Resolve the adapter for THIS chat's agent (frontmatter "agent"), not the
  -- global default, so the lightweight utility call runs on the right CLI
  -- (e.g. a codex chat generates its title via the codex adapter, not claude).
  -- Title generation never resumes/forks the session (it sends a fresh bounded
  -- excerpt), so no session_id is threaded through here.
  -- Resolution failure must never block title generation, so fall back to the
  -- default adapter (nil → title_generator uses vibing.get_adapter()).
  local title_adapter = nil
  if chat_buffer.parse_frontmatter then
    local ok_adapter, resolved = pcall(function()
      local SendMessage = require("vibing.application.chat.send_message")
      return SendMessage._resolve_adapter(vibing.get_adapter(), {
        parse_frontmatter = function()
          return chat_buffer:parse_frontmatter()
        end,
      }, config)
    end)
    if ok_adapter then
      title_adapter = resolved
    end
  end

  title_generator.generate_from_conversation(conversation, function(title, err)
    if err then
      -- Don't fail the rename just because AI title generation failed (prompt
      -- too long, CLI/cache issues, offline). Fall back to a name derived from
      -- the first user message; generate_with_title turns "" into "untitled".
      title = first_user_line(conversation) or ""
      notify.warn(string.format("Title generation failed (%s); using message-based name", err))
    end

    if not chat_buffer.buf or not vim.api.nvim_buf_is_valid(chat_buffer.buf) then
      notify.warn("Buffer was closed before title generation completed")
      return
    end

    local new_filename = filename_util.generate_with_title(title, "chat")
    local normalized_dir = ensure_trailing_slash(save_dir)

    Fs.ensure_dir(normalized_dir)

    local new_file_path = get_unique_file_path(save_dir, new_filename)

    if is_existing_file then
      local ok, save_err = save_buffer(chat_buffer.buf)
      if not ok then
        notify.error(string.format("Failed to save: %s", save_err))
        return
      end

      local rename_result = vim.fn.rename(old_file_path, new_file_path)
      if rename_result ~= 0 then
        notify.error("Failed to rename file")
        return
      end
    end

    -- Notify LSP clients about file rename
    local old_uri = vim.uri_from_bufnr(chat_buffer.buf)

    vim.api.nvim_buf_set_name(chat_buffer.buf, new_file_path)
    chat_buffer.file_path = new_file_path

    -- Notify all LSP clients: didClose old URI, didOpen new URI
    local clients = vim.lsp.get_clients({ bufnr = chat_buffer.buf })
    for _, client in ipairs(clients) do
      if client.server_capabilities.textDocumentSync then
        -- didClose for old URI
        if client.notify then
          client.notify("textDocument/didClose", {
            textDocument = { uri = old_uri }
          })
        end

        -- didOpen for new URI
        local new_uri = vim.uri_from_bufnr(chat_buffer.buf)
        local buflines = vim.api.nvim_buf_get_lines(chat_buffer.buf, 0, -1, false)
        local text = table.concat(buflines, "\n")

        if client.notify then
          client.notify("textDocument/didOpen", {
            textDocument = {
              uri = new_uri,
              languageId = vim.bo[chat_buffer.buf].filetype,
              version = 0,
              text = text,
            }
          })
        end
      end
    end

    if not is_existing_file then
      local ok, save_err = save_buffer(chat_buffer.buf)
      if not ok then
        notify.error(string.format("Failed to save: %s", save_err))
        return
      end
    end

    notify.info(string.format("Renamed to: %s", vim.fn.fnamemodify(new_file_path, ":.")))

    if is_existing_file then
      -- Daily summaryのベースディレクトリを取得
      local daily_base_dir
      if config.daily_summary and config.daily_summary.save_dir then
        daily_base_dir = config.daily_summary.save_dir
      else
        daily_base_dir = save_dir
      end

      -- Daily summaryリンクの更新
      local daily_result = SyncManager.sync_links(
        old_file_path, new_file_path, { DailySummaryScanner.new() }, daily_base_dir
      )

      -- チャット間リンクの更新（チャット保存ディレクトリを検索）。
      -- daily summary と違ってベースディレクトリが同じなので、1回の呼び出しにまとめられる
      local chat_result = SyncManager.sync_links(
        old_file_path,
        new_file_path,
        { ForkedChatScanner.new(), OrchestrationChatScanner.new() },
        save_dir
      )

      local total_updated = daily_result.updated + chat_result.updated
      local total_failed = daily_result.failed + chat_result.failed

      if total_updated > 0 then
        notify.info(string.format("Updated %d linked file(s)", total_updated), "Link Sync")
      end
      if total_failed > 0 then
        notify.warn(string.format("Failed to update %d file(s)", total_failed), "Link Sync")
      end
    end
  end, title_adapter, { summary = summary })

  return true
end
