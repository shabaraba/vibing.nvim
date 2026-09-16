---@class Vibing.Application.Chat.SummarizeAndTitle
---`:VibingSummarize` と `:VibingSetFileTitle` の実体。要約とタイトル生成を1つのチャットに
---適用し、`--linked` ならリンクで繋がったチャットにも同じ処理を順に流す。
---
---**逐次に流すのは意図的**。どちらも軽量ユーティリティ呼び出しで、並行に投げれば速いが、
---1コマンドでリンク網ぶんのCLIプロセスが同時に立つ。改名はリンク先の frontmatter を
---書き換えるので、並行に走らせると同じファイルへの書き込みが重なりもする。
---
---1チャットの失敗は次へ進む理由を変えない。「要約する会話が無い」も「ストリーミング中」も
---そのチャット固有の事情で、隣のチャットには当てはまらない。数え上げて最後に報告する。
---
---逐次である以上、所要時間は件数に比例して伸びる。総件数は起点に手を付ける前に確定させ、
---進捗は右下のフロート（`presentation/common/progress.lua`）に出しっぱなしにする。
---通知で1件ずつ流すと件数ぶん積み上がり、「いま何件目か」は最新行を探さないと読めない。
local M = {}

local notify = require("vibing.core.utils.notify")

---@class Vibing.Application.Chat.SummarizeAndTitle.Opts
---@field summarize boolean 要約を生成するか
---@field with_title boolean タイトルを生成して改名するか
---@field linked boolean リンクで繋がったチャットにも同じ処理をするか

---@class Vibing.Application.Chat.SummarizeAndTitle.Progress
---@field total integer 起点を含む総件数
---@field failed integer 成功数は `total - failed`。全件が1回ずつ決着するので別に数えない
---@field ui Vibing.Progress.Handle

---1つのチャットに要約とタイトル生成を順に適用する
---@param chat_buffer Vibing.ChatBuffer
---@param opts Vibing.Application.Chat.SummarizeAndTitle.Opts
---@param done fun(ok: boolean)
---@param quiet boolean? 改名後の名前は呼び出し側が見せるので `set_file_title` は通知しない
local function run_one(chat_buffer, opts, done, quiet)
  local function title()
    require("vibing.application.chat.handlers.set_file_title")({}, chat_buffer, { quiet = quiet, on_done = done })
  end

  if not opts.summarize then
    return title()
  end

  require("vibing.application.chat.use_case").generate_and_insert_summary(chat_buffer, {
    on_done = function(ok)
      -- 要約が失敗したらタイトル生成へは進まない。summary が無いまま走らせるとタイトル生成は
      -- 抜粋にフォールバックし、ユーザーが頼んでいない API 呼び出しが1回余分に走る。
      if not ok or not opts.with_title then
        return done(ok)
      end
      title()
    end,
  })
end

---チャットファイルのパスを表示用の短い名前にする（未保存の起点では nil が来る）
---@param path string?
---@return string
local function display_name(path)
  return path and vim.fn.fnamemodify(path, ":t") or "this chat"
end

---1件ぶんの結末を、集計と表示の両方に書き込む
---
---「1件終わったとはどういうことか」の定義はここ1つ。起点とリンク先で2回書くと、片方だけ
---直した版が黙って通る
---@param progress Vibing.Application.Chat.SummarizeAndTitle.Progress
---@param opts Vibing.Application.Chat.SummarizeAndTitle.Opts
---@param chat_buffer Vibing.ChatBuffer 改名後の名前を持っているバッファ
---@param position integer 木の上での行番号（1始まり、起点が1）
---@param ok boolean
local function settle(progress, opts, chat_buffer, position, ok)
  if not ok then
    progress.failed = progress.failed + 1
  end
  if opts.with_title then
    -- 改名に失敗していれば `file_path` は変わっていないので、貼り直しても同じ名前になる
    progress.ui:relabel(position, display_name(chat_buffer.file_path))
  end
  progress.ui:mark(position, ok)
end

---リンク先のチャットを1つずつ処理する
---@param targets {path: string, abs: string, bufnr: number?, depth: integer}[]
---@param opts Vibing.Application.Chat.SummarizeAndTitle.Opts
---@param progress Vibing.Application.Chat.SummarizeAndTitle.Progress 起点の結果まで含めた集計
local function run_linked(targets, opts, progress)
  local ChatLocator = require("vibing.application.chat.chat_locator")
  local view = require("vibing.presentation.chat.view")

  local index = 0

  local function step()
    index = index + 1
    if index > #targets then
      -- フロートは読める間だけ残って消える。あとから確かめたくなるのは集計のほうなので、
      -- そちらは `:messages` に残る通知でも出す
      local done = string.format("Done: %d updated, %d failed", progress.total - progress.failed, progress.failed)
      progress.ui:finish(done)
      notify.info(done, "Linked Chats")
      return
    end

    local target = targets[index]
    -- 起点が1件目なので、リンク先は2件目から数える
    local position = index + 1
    progress.ui:start(position)

    local function warn(reason)
      notify.warn(string.format("%s: %s", display_name(target.abs), reason), "Linked Chats")
    end
    ---開けなかったチャットは名前を貼り直す相手がいないので、いまの名前のまま失敗にする
    ---@param reason string
    local function skip(reason)
      warn(reason)
      progress.failed = progress.failed + 1
      progress.ui:mark(position, false)
      return step()
    end

    -- 開いていないチャットは背景で開く。リンク網のノードの大半は窓なしのワーカーで、
    -- 「閉じているから届かない」は `--linked` の答えにならない
    local ok_open, bufnr = pcall(ChatLocator.open, target.path)
    if not ok_open then
      return skip(tostring(bufnr))
    end

    local chat_buffer = view.get_chat_buffer(bufnr)
    if not chat_buffer then
      return skip("could not attach a chat buffer")
    end

    run_one(chat_buffer, opts, function(ok)
      -- 書き込んだ内容はここで保存する。要約の挿入はバッファを書き換えるだけで、ディスクへ
      -- 落とすのは改名の経路（`set_file_title`）しかない。ユーザーが開いてもいないバッファを
      -- modified のまま残すと、要約したと報告したファイルの中身が変わっておらず、そのうえ
      -- `:qa` が E37 で止まる
      local saved, save_err = true, nil
      if ok then
        saved, save_err = require("vibing.presentation.chat.modules.file_manager").save_buffer(chat_buffer.buf)
        if not saved then
          warn(save_err or "could not save the buffer")
        end
      end

      settle(progress, opts, chat_buffer, position, ok and saved)
      step()
    end, true)
  end

  step()
end

---@param origin Vibing.ChatBuffer
---@param opts Vibing.Application.Chat.SummarizeAndTitle.Opts
function M.run(origin, opts)
  -- リンク先は**起点を処理する前に**数え上げる。改名はリンク先の frontmatter を書き換えるので、
  -- 走査を挟むならリンクがまだ元の名前を指している側で済ませる。
  -- 件数が確定するのもここなので、起点のCLI呼び出しを待たせずに先に知らせる
  local targets = opts.linked and require("vibing.application.chat.linked_chats").collect(origin.file_path, origin.buf)
    or {}

  if #targets == 0 then
    if opts.linked then
      notify.info("No linked chats found", "Linked Chats")
    end
    return run_one(origin, opts, function() end)
  end

  -- 起点が木の根。リンク先は `collect` が付けた深さのまま並んでいるので、そのまま繋げると
  -- 処理する順に上から読める木になる
  local items = { { label = display_name(origin.file_path), depth = 0 } }
  for _, target in ipairs(targets) do
    table.insert(items, { label = display_name(target.abs), depth = target.depth })
  end

  local progress = {
    total = #items,
    failed = 0,
    ui = require("vibing.presentation.common.progress").open({ title = "Linked Chats", items = items }),
  }
  progress.ui:start(1)

  run_one(origin, opts, function(ok)
    settle(progress, opts, origin, 1, ok)
    run_linked(targets, opts, progress)
  end, true)
end

return M
