---@class Vibing.Infrastructure.RPC.ChatHandler
---RPC handler for programmatic chat buffer creation (MCP tool `nvim_chat_create`)
local M = {}

local ChatConstants = require("vibing.core.constants.chat")
local FileManager = require("vibing.presentation.chat.modules.file_manager")

---新しいチャットバッファを作成する
---@param params {position?: string, working_dir?: string, from_bufnr?: number, task?: string, delegated_scope?: string[]}
---@return {bufnr: number, file_path: string, working_dir: string?, position: string, saved: boolean}
function M.create_chat(params)
  params = params or {}

  local position = params.position or "back"
  if not ChatConstants.is_valid_position(position) then
    error(
      string.format(
        "Invalid position: %s (expected one of: %s)",
        tostring(position),
        table.concat(ChatConstants.POSITIONS, ", ")
      )
    )
  end

  -- チャットを作る**前**に検証する。作ったあとに弾くと、拒否されたのに空のワーカーチャットと
  -- そのファイルだけが残る
  local from_bufnr = require("vibing.infrastructure.rpc.handlers.bufnr").resolve_from_bufnr(params.from_bufnr)

  -- taskは新しいチャット自身のfrontmatterには書かない。`from_bufnr`（親）の`orchestrated`
  -- エントリにのみ記録する（#696フォローアップ）ので、`from_bufnr`が無ければ書き込み先が無く、
  -- 黙って捨てるより先に伝える
  if params.task and params.task ~= "" and not from_bufnr then
    require("vibing.core.utils.notify").warn(
      "task was given without from_bufnr, so there is nowhere to record it; ignoring",
      "Orchestration"
    )
  end

  -- delegated_scopeも他の許可リストと同じ`tools.validate_tool()`を通す。パターン構文を
  -- `permissions_allow`と揃えるだけでなく、フロントマターの行として書けない値（改行を含む
  -- 文字列など）をチャットを作る**前**に弾く。無効な要素は`from_bufnr`の無いtaskと同じく、
  -- 落とすだけでチャット作成自体は続ける（非table全体を無視するのと同じ寛容さ）
  local delegated_scope = {}
  if type(params.delegated_scope) == "table" then
    local tools = require("vibing.core.constants.tools")
    for _, pattern in ipairs(params.delegated_scope) do
      local valid_pattern = type(pattern) == "string" and pattern ~= "" and tools.validate_tool(pattern)
      if valid_pattern then
        table.insert(delegated_scope, valid_pattern)
      end
    end
  end

  local session = require("vibing.application.chat.use_cases.create_chat").execute({
    working_dir = params.working_dir,
  })
  -- background: ワーカーはユーザーが開いたチャットではないので、`view._current_buffer`
  -- （:VibingCancel などのフォールバック先）を奪わない
  local chat_buf = require("vibing.presentation.chat.view").render(session, position, { background = true })

  -- delegated_scopeはこの新しいチャット**自身**のfrontmatterに書く（taskとは逆）。
  -- `approval_delegate`が"scoped"モードで照らすのは答えるワーカー自身の宣言であって、
  -- 誰が作ったかではないため
  for _, pattern in ipairs(delegated_scope) do
    chat_buf:update_frontmatter_list("delegated_scope", pattern, "add")
  end

  -- `:VibingChat`は最初の応答が返るまでファイルを書かない（buffer.lua:update_session_id）。
  -- 呼び出し元にファイルパスを返す以上、そのパスが存在しないのは嘘なので、forkと同じく
  -- 作成時点で保存する
  FileManager.save_buffer(chat_buf.buf)

  -- 作成した時点でリンクを張る。送信を待つ形でも記録はできるが、`from_bufnr` の渡し忘れが
  -- 「黙って関係が残らない」失敗になるので、関係が確定する最も早い時点で書く
  if from_bufnr then
    local ok, err = require("vibing.application.chat.orchestration_link").link(from_bufnr, chat_buf.buf, params.task)
    if not ok then
      require("vibing.core.utils.notify").warn(
        string.format("Created chat %d but could not link it: %s", chat_buf.buf, err or "unknown"),
        "Orchestration"
      )
    end

    -- 作成でも購読を張る。送信だけを登録にすると、ブリーフに `from_bufnr` を渡し忘れたときに
    -- 「黙って通知が来ない」で終わる。作ってメッセージを送らないケースは無いので、
    -- 早い方に寄せておくほうが渡し忘れに強い。
    --
    -- リンクの書き込みが失敗しても購読は張る（意図的な非対称）。frontmatter が書けないと
    -- ワーカーは「誰に報告すればいいか」の行を得られない（`send_message` が
    -- `orchestrated_by` を読むため）が、オーケストレーター側が完了を知る手段まで一緒に
    -- 失う理由はない。通知はインメモリで、frontmatter を必要としない
    require("vibing.application.chat.completion_notifier").subscribe(from_bufnr, chat_buf.buf)
  end

  return {
    bufnr = chat_buf.buf,
    file_path = chat_buf.file_path,
    working_dir = session.working_dir,
    position = position,
    -- リンク書き込みはバッファを変更して保存し直すので、`saved` はその**後**に見る。
    -- 先にスナップショットすると、リンクの無いディスク上のコピーに対して true を返しうる
    saved = not vim.bo[chat_buf.buf].modified,
  }
end

---別のチャットのツール承認プロンプトに代理で答える（MCP tool `nvim_chat_answer_approval`）
---
---宛先の指し方は `nvim_chat_send_message` と同じ（`file_path` か `bufnr` のどちらか一方）。
---違うのは `from_bufnr` が**必須**なこと: 承認ゲートを外す呼び出しなので、誰が外したのかを
---記録できない形は通さない。互換のために任意にしておく理由も無い — このRPCメソッドを持たない
---古いNeovimは、呼び出しそのものが届かない
---@param params {bufnr?: number, file_path?: string, action: string, from_bufnr: number}
---@return {success: boolean, bufnr: number, tool: string, action: string}
function M.answer_approval(params)
  params = params or {}

  local Bufnr = require("vibing.infrastructure.rpc.handlers.bufnr")
  local bufnr = Bufnr.resolve_chat_target(params)
  if not bufnr then
    error("Missing bufnr or file_path parameter")
  end

  local from_bufnr = Bufnr.resolve_from_bufnr(params.from_bufnr)
  if not from_bufnr then
    error("Missing from_bufnr parameter (the chat answering the prompt must name itself)")
  end

  return require("vibing.application.chat.approval_delegate").answer({
    bufnr = bufnr,
    action = params.action,
    from_bufnr = from_bufnr,
  })
end

---直近ターンの `### Tokens <!-- context=N --> ` からcontextを読む
---
---`cache_expiry.read_last_turn` は `nvim_buf_get_lines(buf, 0, -1, false)` でバッファ全文を
---Luaテーブルにコピーしてから末尾を探す。1チャットの送信時に1回だけ呼ぶ分にはそれで良いが、
---`list_chats` は開いている全チャットぶんこれを呼ぶ — 「複数チャットを高頻度にポーリングする」
---という新しい負荷パターンで、長いトランスクリプトのチャットが何本もあるとメインループを
---縛る（`architecture.md` の git スナップショット実測値が示す同種の懸念）。
---
---末尾から倍々にチャンクを広げて読む手口は `infrastructure/rpc/handlers/buffer.lua` の
---`read_last_section` と同じ。マーカーの完全一致だけを見て、`parse_context` のあいまい
---フォールバック（`context 150k` のような地の文にも一致しうる）は使わない — こちらは
---「直近ターンの範囲内」という境界を持たないので、あいまい一致まで許すと本文の引用に
---誤って反応しかねない
---@param bufnr number
---@return number? context_size
local function read_context_size(bufnr)
  local TokenUsage = require("vibing.core.utils.token_usage")
  local total_lines = vim.api.nvim_buf_line_count(bufnr)
  local chunk_size = 500

  while true do
    local from = math.max(0, total_lines - chunk_size)
    local chunk = vim.api.nvim_buf_get_lines(bufnr, from, total_lines, false)

    for i = #chunk, 1, -1 do
      if chunk[i]:match("^###%s+Tokens") then
        return TokenUsage.parse_context(chunk[i])
      end
    end

    if from == 0 then
      return nil
    end
    chunk_size = chunk_size * 2
  end
end

---`view.list_chat_buffers()`が返すbufnrをソート済みの配列にする。`list_chats`と
---`chat_conflicts`の両方が「毎回同じ順序で列挙する」ために同じ手順を踏むので、ここで共有する
---@param buffers table<number, Vibing.ChatBuffer>
---@return number[]
local function sorted_bufnrs(buffers)
  local bufnrs = {}
  for bufnr in pairs(buffers) do
    table.insert(bufnrs, bufnr)
  end
  table.sort(bufnrs)
  return bufnrs
end

---taskはチャット自身のfrontmatterではなく、それを頼んだ親の`orchestrated`エントリにしか
---無い（#696フォローアップ）。今このセッションで開いている全チャットの`orchestrated`を
---展開し、一致するbufnrの行（`by_absolute_path`）に投影する — 対象は既に読み込み済みのチャット
---だけなので、このためだけに追加でファイルを開いたりバッファ全文を読んだりはしない。
---`list_chats` と `chat_conflicts` の両方が使うので、ここで共有する
---@param buffers table<number, Vibing.ChatBuffer>
---@param bufnrs number[]
---@param by_absolute_path table<string, {task: string?}> 絶対パス→投影先エントリ
---@param git_root string? 呼び出し元が既に持っているなら渡す（`git rev-parse`の起動を1回省く）
local function project_tasks(buffers, bufnrs, by_absolute_path, git_root)
  local OrchestratedEntry = require("vibing.application.chat.orchestrated_entry")
  local Git = require("vibing.core.utils.git")
  for _, bufnr in ipairs(bufnrs) do
    local orchestrated = buffers[bufnr]:get_frontmatter_list("orchestrated")
    if #orchestrated > 0 then
      git_root = git_root or Git.get_root()
      for _, item in ipairs(orchestrated) do
        local path, task = OrchestratedEntry.decode(item)
        if task then
          local abs = vim.fn.fnamemodify(Git.from_display_path(path, git_root), ":p")
          local target = by_absolute_path[abs]
          if target then
            target.task = task
          end
        end
      end
    end
  end
end

---生きているチャットバッファをすべて列挙する（MCP tool `nvim_chat_list`）
---
---1チャットずつ `nvim_get_buffer` を叩くとNチャットでN往復かかる（#692の実走ではPythonの
---RPCポーラーで迂回した）。列挙元は `view.list_chat_buffers()` 一択 — 「いま何本開いているか」
---を知る手段はそれしかない（`application/chat/concurrency.lua` も同じものを読む）ので、
---閉じたまま残っているチャットファイルはここには載らない
---@return {chats: {bufnr: number, file_path: string?, chat_status: string?, context_size: number?, updated_at: string?, orchestrated_by: string[], task: string?}[]}
function M.list_chats(_)
  local view = require("vibing.presentation.chat.view")
  local ChatStatus = require("vibing.presentation.chat.modules.chat_status")

  local buffers = view.list_chat_buffers()
  local bufnrs = sorted_bufnrs(buffers)

  local chats = {}
  local by_absolute_path = {}
  for _, bufnr in ipairs(bufnrs) do
    local chat_buf = buffers[bufnr]
    local frontmatter = chat_buf:parse_frontmatter()

    local entry = {
      bufnr = bufnr,
      file_path = chat_buf.file_path,
      chat_status = ChatStatus.get(bufnr),
      context_size = read_context_size(bufnr),
      updated_at = frontmatter.updated_at,
      orchestrated_by = chat_buf:get_frontmatter_list("orchestrated_by"),
    }
    table.insert(chats, entry)
    if chat_buf.file_path then
      by_absolute_path[vim.fn.fnamemodify(chat_buf.file_path, ":p")] = entry
    end
  end

  project_tasks(buffers, bufnrs, by_absolute_path)

  return { chats = chats }
end

---mainリポジトリで解決できる基準ブランチ名を返す。全worktreeでrefは共有されるので、
---1回だけ解決してすべてのチャットのdiffに使い回す。どちらも無ければnil（#699はwarnのみで
---ブロックしないので、呼び出し元は黙って`conflicts = {}`にする）
---@param git_root string
---@return string?
local function resolve_base_branch(git_root)
  for _, name in ipairs({ "main", "master" }) do
    local ok, result = pcall(function()
      return vim.system({ "git", "rev-parse", "--verify", "--quiet", name }, { cwd = git_root, text = true }):wait()
    end)
    if ok and result and result.code == 0 then
      return name
    end
  end
  return nil
end

---あるチャットのworktreeが`base`から変更したファイル名一覧を返す。`.vibing/`（worktree自体を
---含む）は除外する。gitが失敗したら（`base`との merge base が無い、worktreeが消えている）
---nilとその理由を返す。呼び出し元はそのチャットを`skipped`に載せる — 黙って外すと
---`conflicts = {}`が「衝突なし」に読めてしまい、この道具が要る場面でこそ嘘をつく
---@param worktree string 絶対パス
---@param base string
---@return string[]? files
---@return string? reason gitの言い分。filesがnilのときだけ
local function diff_against_base(worktree, base)
  local ok, result = pcall(function()
    return vim.system({
      "git",
      "-c",
      "core.quotePath=false",
      "diff",
      "--name-only",
      base .. "...HEAD",
      "--",
      ".",
      ":(exclude).vibing",
    }, { cwd = worktree, text = true }):wait()
  end)
  if not ok then
    return nil, tostring(result)
  end
  if not result or result.code ~= 0 then
    local reason = result and vim.trim(result.stderr or "") or ""
    if reason == "" then
      reason = "git exited with code " .. tostring(result and result.code)
    end
    return nil, reason
  end

  return vim.split(result.stdout or "", "\n", { trimempty = true }), nil
end

---生きているチャットのうち、2本以上のworking_dirブランチが同じファイルを触っていないか
---警告する（MCP tool `nvim_chat_conflicts`, #699）。#692の事後分析で実際に起きた事故——
---2つのPRが同じ見出しフォーマットの前提を別々に変え、片方のテストは自前フィクスチャなので
---気づかれなかった——をORCHESTRATORが自分でファイル名を突き合わせなくても検出できるようにする。
---
---警告のみでブロックしない。v1はファイル単位（hunk単位はやらない）。`working_dir`を持たない
---チャット（Neovimインスタンス自身のcwdを使う）は比較対象にしない — 比較基準そのものが
---mainなので、自分自身との差分は意味を持たない。
---
---比較できなかったものは黙って落とさない: diffに失敗したチャットは`skipped`にgitの理由付きで
---載せ、基準ブランチが無ければ`warning`を返す。空の`conflicts`は「衝突なし」に読まれるので、
---「見ていない」をそれと区別できる形で返す
---@return {base: string?, conflicts: {file: string, chats: {bufnr: number, file_path: string?, task: string?}[]}[], skipped: {bufnr: number, file_path: string?, working_dir: string?, reason: string}[], warning: string?}
function M.chat_conflicts(_)
  local view = require("vibing.presentation.chat.view")
  local Git = require("vibing.core.utils.git")

  local git_root = Git.get_root()
  if not git_root then
    return { conflicts = {}, skipped = {}, warning = "Not inside a git repository, so no chat was compared." }
  end
  local base = resolve_base_branch(git_root)
  if not base then
    return {
      conflicts = {},
      skipped = {},
      warning = string.format("Neither main nor master resolves in %s, so no chat was compared.", git_root),
    }
  end

  local buffers = view.list_chat_buffers()
  local bufnrs = sorted_bufnrs(buffers)

  ---@type table<string, table[]>
  local contributors_by_file = {}
  local by_absolute_path = {}
  local skipped = {}
  for _, bufnr in ipairs(bufnrs) do
    local chat_buf = buffers[bufnr]
    local frontmatter = chat_buf:parse_frontmatter()
    local worktree = Git.resolve_working_dir(frontmatter.working_dir, git_root)
    -- working_dir == "." resolves to git_root itself (a documented `resolve_working_dir`
    -- behavior other callers rely on) -- that is the instance's own working directory, not a
    -- worktree of its own, so it gets the same exclusion as no working_dir at all (see the
    -- docstring above)
    if worktree and worktree ~= git_root then
      local files, reason = diff_against_base(worktree, base)
      if files then
        local entry = { bufnr = bufnr, file_path = chat_buf.file_path }
        if chat_buf.file_path then
          by_absolute_path[vim.fn.fnamemodify(chat_buf.file_path, ":p")] = entry
        end
        for _, file in ipairs(files) do
          contributors_by_file[file] = contributors_by_file[file] or {}
          table.insert(contributors_by_file[file], entry)
        end
      else
        table.insert(skipped, {
          bufnr = bufnr,
          file_path = chat_buf.file_path,
          working_dir = frontmatter.working_dir,
          reason = reason,
        })
      end
    end
  end

  project_tasks(buffers, bufnrs, by_absolute_path, git_root)

  local files_sorted = {}
  for file in pairs(contributors_by_file) do
    table.insert(files_sorted, file)
  end
  table.sort(files_sorted)

  local conflicts = {}
  for _, file in ipairs(files_sorted) do
    local chats = contributors_by_file[file]
    if #chats >= 2 then
      table.insert(conflicts, { file = file, chats = chats })
    end
  end

  return { base = base, conflicts = conflicts, skipped = skipped }
end

return M
