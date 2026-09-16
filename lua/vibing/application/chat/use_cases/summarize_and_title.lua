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
local M = {}

local notify = require("vibing.core.utils.notify")

---@class Vibing.Application.Chat.SummarizeAndTitle.Opts
---@field summarize boolean 要約を生成するか
---@field with_title boolean タイトルを生成して改名するか
---@field linked boolean リンクで繋がったチャットにも同じ処理をするか

---1つのチャットに要約とタイトル生成を順に適用する
---@param chat_buffer Vibing.ChatBuffer
---@param opts Vibing.Application.Chat.SummarizeAndTitle.Opts
---@param done fun(ok: boolean)
local function run_one(chat_buffer, opts, done)
  local function title()
    require("vibing.application.chat.handlers.set_file_title")({}, chat_buffer, { on_done = done })
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

---リンク先のチャットを1つずつ処理する
---@param targets {path: string, abs: string, bufnr: number?}[]
---@param opts Vibing.Application.Chat.SummarizeAndTitle.Opts
local function run_linked(targets, opts)
  local ChatLocator = require("vibing.application.chat.chat_locator")
  local view = require("vibing.presentation.chat.view")

  if #targets == 0 then
    return notify.info("No linked chats found", "Linked Chats")
  end
  notify.info(string.format("Processing %d linked chat(s)...", #targets), "Linked Chats")

  local index, succeeded, failed = 0, 0, 0

  local function step()
    index = index + 1
    if index > #targets then
      notify.info(string.format("Linked chats: %d updated, %d failed", succeeded, failed), "Linked Chats")
      return
    end

    local target = targets[index]
    local function warn(reason)
      notify.warn(string.format("%s: %s", vim.fn.fnamemodify(target.abs, ":t"), reason), "Linked Chats")
    end
    local function skip(reason)
      failed = failed + 1
      warn(reason)
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

      if ok and saved then
        succeeded = succeeded + 1
      else
        failed = failed + 1
      end
      step()
    end)
  end

  step()
end

---@param origin Vibing.ChatBuffer
---@param opts Vibing.Application.Chat.SummarizeAndTitle.Opts
function M.run(origin, opts)
  -- リンク先は**起点を処理する前に**数え上げる。改名はリンク先の frontmatter を書き換えるので、
  -- 走査を挟むならリンクがまだ元の名前を指している側で済ませる
  local targets = opts.linked
      and require("vibing.application.chat.linked_chats").collect(origin.file_path, origin.buf)
    or {}

  run_one(origin, opts, function()
    if opts.linked then
      run_linked(targets, opts)
    end
  end)
end

return M
