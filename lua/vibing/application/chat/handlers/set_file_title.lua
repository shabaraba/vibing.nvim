local notify = require("vibing.core.utils.notify")
local title_generator = require("vibing.core.utils.title_generator")
local filename_util = require("vibing.core.utils.filename")
local FileManager = require("vibing.presentation.chat.modules.file_manager")
local RenameSync = require("vibing.application.link.rename_sync")
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

---改名をLSPクライアントに伝える（旧URIのdidClose、新URIのdidOpen）
---@param buf number
---@param old_uri string
local function notify_lsp_rename(buf, old_uri)
  for _, client in ipairs(vim.lsp.get_clients({ bufnr = buf })) do
    if client.server_capabilities.textDocumentSync and client.notify then
      client.notify("textDocument/didClose", { textDocument = { uri = old_uri } })
      client.notify("textDocument/didOpen", {
        textDocument = {
          uri = vim.uri_from_bufnr(buf),
          languageId = vim.bo[buf].filetype,
          version = 0,
          text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n"),
        },
      })
    end
  end
end

---チャットファイルにAI生成のタイトルを付けて改名する
---
---`opts.on_done` は成否にかかわらず必ず1回だけ呼ばれる。同期的な早期リターン（ストリーミング
---中・会話が空）でも呼ぶのが要点で、呼ばれない経路が1つでもあると連鎖する呼び出し側
---（`:VibingSummarize --linked` の逐次実行）は「まだ来ていない」と「もう来ない」を区別できず
---待ち続ける。
---@param _ string[]
---@param chat_buffer Vibing.ChatBuffer
---@param opts? {on_done?: fun(ok: boolean)}
---@return boolean
return function(_, chat_buffer, opts)
  local on_done = opts and opts.on_done
  ---`ok` をそのまま返すので、早期リターンは `return finish(false)` と書ける。この形のおかげで
  ---「全ての出口で1回呼ばれる」がコードを目で追うだけで確かめられる
  ---@param ok boolean
  ---@return boolean ok
  local function finish(ok)
    if on_done then
      -- 非同期パスでは CLI の完了ハンドラ（luv のコールバック内）から呼ばれる。素通しにすると
      -- そこで例外になるので、`generate_and_insert_summary` と同じく捕まえて通知に落とす
      local ok_call, err = pcall(on_done, ok)
      if not ok_call then
        notify.error("Title completion callback failed: " .. tostring(err))
      end
    end
    return ok
  end

  if not chat_buffer or not chat_buffer.buf or not vim.api.nvim_buf_is_valid(chat_buffer.buf) then
    notify.error("No valid chat buffer")
    return finish(false)
  end

  -- ストリーミング中はバッファがまだ確定していない。会話は途中状態なのでそこからタイトルを
  -- 作ることになるし、リネームのための `:write!` が応答の追記と競合する。
  -- （#475 当時の理由だった「同一 session_id への resume 競合」は、タイトル生成が resume を
  -- やめた時点で消えている。残っているのは上の2つ。）
  if chat_buffer:is_sending() then
    notify.warn("Cannot generate title while a response is streaming")
    return finish(false)
  end

  local conversation = chat_buffer:extract_conversation()
  if #conversation == 0 then
    notify.warn("No conversation to generate title from")
    return finish(false)
  end

  -- `:VibingSummarize` が書いた `## summary` があれば、抜粋ではなくそちらを入力にする。
  -- summary は既に「会話全体で何をしたか」に圧縮されているので、長い会話でも主題を外しにくく、
  -- 送るテキストも短い。無ければ従来どおり抜粋にフォールバックする（後方互換）。
  local summary = SummaryInserter.extract(chat_buffer.buf)

  local old_file_path = chat_buffer.file_path
  local config = require("vibing").get_config()
  local save_dir = FileManager.get_save_directory(config.chat)
  local is_existing_file = old_file_path and vim.fn.filereadable(old_file_path) == 1

  -- 改名は**そのファイルのあるディレクトリの中**で行う。設定の保存先へ寄せると、別プロジェクトの
  -- チャットを開いているとき（`--linked` はそこまで辿る）に会話ファイルが物理的に引っ越し、
  -- 引っ越し元に残ったリンクは `RenameSync` の走査範囲の外なので誰も直さない。
  -- まだ保存されていないチャットだけが、設定の保存先に置かれる
  local target_dir = is_existing_file and vim.fn.fnamemodify(old_file_path, ":h") or save_dir

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
      return finish(false)
    end

    local new_filename = filename_util.generate_with_title(title, "chat")
    Fs.ensure_dir(ensure_trailing_slash(target_dir))

    local new_file_path = get_unique_file_path(target_dir, new_filename)

    if is_existing_file then
      local ok, save_err = FileManager.save_buffer(chat_buffer.buf)
      if not ok then
        notify.error(string.format("Failed to save: %s", save_err))
        return finish(false)
      end

      if vim.fn.rename(old_file_path, new_file_path) ~= 0 then
        notify.error("Failed to rename file")
        return finish(false)
      end
    end

    local old_uri = vim.uri_from_bufnr(chat_buffer.buf)

    vim.api.nvim_buf_set_name(chat_buffer.buf, new_file_path)
    chat_buffer.file_path = new_file_path

    notify_lsp_rename(chat_buffer.buf, old_uri)

    if not is_existing_file then
      local ok, save_err = FileManager.save_buffer(chat_buffer.buf)
      if not ok then
        notify.error(string.format("Failed to save: %s", save_err))
        return finish(false)
      end
    end

    notify.info(string.format("Renamed to: %s", vim.fn.fnamemodify(new_file_path, ":.")))

    if is_existing_file then
      -- リンクを探すのは改名したチャットと同じディレクトリ。一緒に作られたチャット同士が
      -- 互いを名指すので、そのチャットを指しているファイルはそこにある。daily summary 側も
      -- 明示設定が無ければ `target_dir` から辿る — `save_dir` に決め打つと別プロジェクトの
      -- チャットを改名したとき（上の `target_dir` と同じ理由）、そのプロジェクトの daily
      -- summary ではなく現在の cwd の daily summary を（誤って）走査してしまう
      local daily_dir = (config.daily_summary and config.daily_summary.save_dir) or target_dir
      RenameSync.apply(old_file_path, new_file_path, target_dir, daily_dir)
    end

    finish(true)
  end, { summary = summary })

  return true
end
