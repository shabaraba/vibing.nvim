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
M.MAX_MESSAGES_FOR_SUMMARY = 50

---1メッセージあたりの上限（文字数）。
---
---件数の上限だけでは効かない。実測したチャットは43通で `MAX_MESSAGES_FOR_SUMMARY` に
---掛からないまま261,741文字あり、うち1通が76,026バイトだった。1通ぶんを縛らないと、
---会話全体の上限を掛けても「巨大な1通だけが残る」形になる。
M.MAX_MESSAGE_CHARS = 3000

---会話全体の上限（文字数）。
---
---`title_generator` が抜粋を6,000文字に縛っているのと同じ理由で、こちらにも上限が要る。
---要約は決定と却下理由が本体なので抜粋よりずっと厚く取るが、上限そのものは要る:
---長すぎるとモデルが `prompts/chat_summary.md` の出力形式を守れなくなり、先頭行が
---`## summary` にならない応答を `summary_inserter` が丸ごと捨てる（= 課金だけされて
---何も挿入されない）。
M.MAX_TOTAL_CHARS = 60000

---中略したことを明示するマーカー。黙って落とすと、要約が会話の一部しか見ていないことが
---読む側にもモデルにも分からない。
M.OMISSION_MARKER = "(… 古いメッセージは省略 …)"

---長すぎるメッセージを中略する。前半と後半の両方を残すのは、assistant の応答では
---「何をしようとしたか」が冒頭に、「何が決まったか」が末尾に来るため。末尾を捨てると
---要約の本体である決定事項がそのまま落ちる。
---@param text string
---@param max_chars integer
---@return string
local function elide_middle(text, max_chars)
  local len = vim.fn.strchars(text)
  if len <= max_chars then
    return text
  end

  local head = math.floor(max_chars * 2 / 3)
  local tail = max_chars - head
  return vim.fn.strcharpart(text, 0, head)
    .. "\n(… 中略 …)\n"
    .. vim.fn.strcharpart(text, len - tail, tail)
end

---要約に渡すメッセージを選ぶ。
---
---ここが `:VibingSummarize` と `title_generator` の分かれ目になる。タイトル生成は
---`chat_excerpt.build` をそのまま使えるが、要約は使えない: `build` は assistant を冒頭2通・
---各400文字しか残さない設計で、要約の本体である「何を決め、何を却下したか」が
---ちょうど落ちる。そこで `chat_excerpt` からはノイズ除去（`clean` / `clean_user`）だけを
---借りて、件数と文字数の制限は要約用に別途かける。
---@param conversation {role: string, content: string}[]
---@return {role: string, content: string}[] messages 新しい順ではなく時系列順
---@return boolean omitted 落としたメッセージがあるか
function M._select_messages_for_summary(conversation)
  local ChatExcerpt = require("vibing.core.utils.chat_excerpt")

  local cleaned = {}
  for _, msg in ipairs(conversation or {}) do
    local text = msg.role == "user" and ChatExcerpt.clean_user(msg.content) or ChatExcerpt.clean(msg.content)
    -- クリーニングで全部消える会話（応答がフェンス済みコードブロックだけ等）は実在する。
    -- 空の <conversation> を送るより、生のテキストを中略して送るほうがまだ要約になる。
    if text == "" then
      text = msg.content or ""
    end
    if vim.trim(text) ~= "" then
      cleaned[#cleaned + 1] = { role = msg.role, content = elide_middle(text, M.MAX_MESSAGE_CHARS) }
    end
  end

  if #cleaned == 0 then
    return {}, false
  end

  -- 新しい側から詰める。引き継ぎ要約の読者が知りたいのは「どこまで進んだか」なので、
  -- 予算が足りないときに落とすのは古いほうが正しい。
  local selected = {}
  local budget = M.MAX_TOTAL_CHARS
  for i = #cleaned, 1, -1 do
    if #selected >= M.MAX_MESSAGES_FOR_SUMMARY then
      break
    end
    local cost = vim.fn.strchars(cleaned[i].content)
    if budget - cost < 0 and #selected > 0 then
      break
    end
    budget = budget - cost
    table.insert(selected, 1, cleaned[i])
  end

  local omitted = #selected < #cleaned

  -- 会話の主題は最初の依頼にある。予算で落ちたときだけ先頭に戻す。1通は中略済みなので
  -- 超過は高々 MAX_MESSAGE_CHARS で、これは上限を緩めるのではなく上限の外の固定費。
  if omitted and selected[1] ~= cleaned[1] then
    table.insert(selected, 1, cleaned[1])
  end

  return selected, omitted
end

---Format conversation for summary prompt with XML protection
---@param conversation table[]
---@return string
local function format_conversation_for_prompt(conversation)
  local messages, omitted = M._select_messages_for_summary(conversation)

  local parts = {}
  for i, msg in ipairs(messages) do
    -- 省略マーカーは先頭の依頼の直後に置く。先頭は主題の固定用に戻したものなので、
    -- そこと次のメッセージのあいだが実際に飛んでいる箇所になる。
    if omitted and i == 2 then
      parts[#parts + 1] = M.OMISSION_MARKER
    end
    -- Wrap in XML tags to prevent prompt injection
    table.insert(parts, string.format("<message role=\"%s\">\n%s\n</message>", msg.role, msg.content))
  end
  if omitted and #messages < 2 then
    parts[#parts + 1] = M.OMISSION_MARKER
  end

  return "<conversation>\n" .. table.concat(parts, "\n") .. "\n</conversation>"
end

---URL が分からない旨をモデルに伝える一文。空文字にはしない: 指示ごと消えると、モデルは
---代わりにもっともらしい URL を組み立てるほうへ倒れる。
local UNKNOWN_ISSUE_URL = "会話に URL が現れていない番号は素のまま書くこと。"

---要約に issue リンクを書かせるための一文を作る
---
---要約は `lightweight` 呼び出しでツールを持たないので、モデルは自分で remote を見に行けない。
---リポジトリ URL をここで解決して渡さないと、`#123` は永久に素のテキストのままになる。
---
---URL の組み立てを許すのは github.com だけ。issue の URL 形は forge ごとに違い（GitLab は
---`/-/issues/`）、`to_web_url` はドットを含む任意のホストを通すので、`/issues/` を例に出すと
---他 forge では存在しないリンクをチャットファイルに書き込むことになる。分からない forge では
---URL だけ渡して番号は素のままにさせる — テンプレートの「URL を推測して組み立てない」を、
---こちらが例文で上書きしないため。
---@param cwd string|nil
---@return string
local function build_repository_instruction(cwd)
  local repo_url = require("vibing.core.utils.repo_url").get(cwd)
  if not repo_url then
    return "このチャットのリポジトリ URL は不明である。" .. UNKNOWN_ISSUE_URL
  end

  local prefix = string.format("このチャットのリポジトリは %s である。", repo_url)

  if not repo_url:match("^https://github%.com/") then
    return prefix .. "issue の URL 形式は不明である。" .. UNKNOWN_ISSUE_URL
  end

  -- 組み立てを許すのは「このリポジトリの番号」だけ。rule 6 は `ABC-456`（他システム）も
  -- `org/repo#123`（別リポジトリ）も表記として認めているので、どちらもこのリポジトリの
  -- issue URL に流し込ませない。後者は特に、開くと無関係な issue に飛ぶリンクになる
  return prefix
    .. string.format(
      "`#123` のようにリポジトリ名の付かない issue / PR 番号は、ここから URL を組み立ててよい"
        .. "（例: `[#123](%s/issues/123)`）。`ABC-456` のような他システムのチケット番号と、"
        .. "`org/repo#123` のように別リポジトリを明示した参照は、URL を組み立てず素のまま書くこと。",
      repo_url
    )
end

---会話からサマリープロンプトを組み立てる
---
---`daily_summary` の `_build_summary_prompt` と同じ理由で切り出してある: プロンプトの組み立ては
---CLI を起動せずにテストできる唯一の接合部で、ここが `prompts/chat_summary.md` の変数名と
---合っているかを確かめる手段が他にない。`substitute_variables` は未知の `{{...}}` を黙って
---残すため、変数名を間違えると空の会話とリテラルの `{{conversation}}` がモデルに渡る。
---@param conversation table[]
---@param cwd? string リポジトリ URL の解決に使う作業ディレクトリ
---@return string|nil prompt
---@return string|nil error
function M._build_summary_prompt(conversation, cwd)
  local PromptLoader = require("vibing.core.utils.prompt_loader")
  return PromptLoader.load("chat_summary", {
    conversation = format_conversation_for_prompt(conversation),
    repository_instruction = build_repository_instruction(cwd),
  })
end

---チャット履歴からサマリーを生成してバッファに挿入
---
---`opts.on_done` は成否にかかわらず必ず1回だけ呼ばれる。同期的な早期リターン（ストリーミング
---中・会話が空・adapter 無し）でも呼ぶのが要点で、呼ばれない経路が1つでもあると連鎖する
---呼び出し側は「まだ来ていない」と「もう来ない」を区別できず待ち続ける。`err` は原則として
---ユーザーに通知したのと同じ文言。挿入失敗だけは例外で、詳しい理由は `SummaryInserter` が
---通知するため `err` は粗い文言になる。
---@param chat_buffer Vibing.ChatBuffer
---@param opts? {on_done?: fun(ok: boolean, err: string?)}
function M.generate_and_insert_summary(chat_buffer, opts)
  local notify = require("vibing.core.utils.notify")
  local on_done = opts and opts.on_done

  local finished = false
  local function finish(ok, err)
    if finished then
      return
    end
    finished = true
    if on_done then
      -- on_done は利用側（dotfiles 等）が書くコールバックで、非同期パスでは CLI の完了
      -- ハンドラの中から呼ばれる。素通しにすると luv のコールバック内で例外になるので、
      -- ここで捕まえて通知に落とす。
      local ok_call, call_err = pcall(on_done, ok, err)
      if not ok_call then
        notify.error("Summary completion callback failed: " .. tostring(call_err))
      end
    end
  end

  if not chat_buffer or not chat_buffer.buf or not vim.api.nvim_buf_is_valid(chat_buffer.buf) then
    notify.error("No valid chat buffer")
    return finish(false, "No valid chat buffer")
  end

  -- set_file_title と同じ理由でストリーミング中は断る。summary は `# Vibing Chat` の直下へ
  -- `nvim_buf_set_lines` で差し込むので、末尾に追記中のストリーミングと行番号で競合しうる。
  -- 加えて、途中状態の会話から要約を作ることにもなる。
  if chat_buffer:is_sending() then
    notify.warn("Cannot summarize while a response is streaming")
    return finish(false, "Cannot summarize while a response is streaming")
  end

  local conversation = chat_buffer:extract_conversation()

  if #conversation == 0 or not has_conversation_content(conversation) then
    notify.warn("No conversation content to summarize")
    return finish(false, "No conversation content to summarize")
  end

  local vibing = require("vibing")
  local adapter = vibing.get_adapter()

  if not adapter then
    notify.error("No adapter configured")
    return finish(false, "No adapter configured")
  end

  local full_prompt, err = M._build_summary_prompt(conversation, chat_buffer:get_cwd())
  if err then
    notify.error("Failed to load summary prompt: " .. err)
    return finish(false, "Failed to load summary prompt: " .. err)
  end

  notify.info("Generating summary...")

  -- Capture buffer reference for async callback validation
  local buf = chat_buffer.buf

  -- 要約はタイトル生成と同じ軽量ユーティリティ呼び出し: ツールも CLAUDE.md も
  -- ユーザーの MCP サーバーも要らず、載せた分だけコンテキストを食う。
  adapter:stream(full_prompt, { lightweight = true }, function(_) end, function(response)
    -- Re-validate buffer in async callback (buffer may be deleted during AI processing)
    if not buf or not vim.api.nvim_buf_is_valid(buf) then
      notify.warn("Chat buffer was closed during summary generation")
      return finish(false, "Chat buffer was closed during summary generation")
    end

    if not response then
      notify.error("No response received from AI")
      return finish(false, "No response received from AI")
    end

    if response.error then
      notify.error(string.format("Summarization failed: %s", response.error))
      return finish(false, string.format("Summarization failed: %s", response.error))
    end

    local summary = response.content
    if not summary or type(summary) ~= "string" or summary == "" then
      notify.warn("AI returned empty summary")
      return finish(false, "AI returned empty summary")
    end

    local SummaryInserter = require("vibing.presentation.chat.modules.summary_inserter")
    -- 失敗の内訳（バッファ無効・`## summary` で始まらない等）は Inserter 側が通知済みなので、
    -- ここでは連鎖する呼び出し側に成否だけを渡す。
    if not SummaryInserter.insert_or_update(buf, summary) then
      return finish(false, "Failed to insert summary into chat buffer")
    end

    notify.info("Summary written to chat buffer")
    finish(true)
  end)
end

return M
