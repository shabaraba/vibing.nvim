---@class Vibing.Application.Chat.OrchestrationLink
---チャット同士のオーケストレーション関係を、双方の frontmatter に記録する。
---
---関係の唯一の記録がトランスクリプトの地の文だったのが元の状態で、それは二重に壊れる。
---bufnr は Neovim を再起動すれば別のバッファを指し、`:VibingSetFileTitle` はチャット
---ファイルを改名するので、書き残したパスは黙って腐る。`forked_from` が frontmatter +
---`ForkedChatScanner` で既に解いている問題なので、同じ形に揃える。
---
---方向を `orchestrated` / `orchestrated_by` の2フィールドに分けているのは、ワーカー側が
---「自分に指示を出したのは誰か」を答えられる必要があるため。隣のワーカーと区別のつかない
---フラットな集合では、そこに答えられない。
local M = {}

local Git = require("vibing.core.utils.git")
local FileManager = require("vibing.presentation.chat.modules.file_manager")
local OrchestratedEntry = require("vibing.application.chat.orchestrated_entry")

---@param bufnr number
---@return table? chat_buf
local function resolve_chat(bufnr)
  if type(bufnr) ~= "number" or not vim.api.nvim_buf_is_valid(bufnr) then
    return nil
  end
  return require("vibing.presentation.chat.view").get_chat_buffer(bufnr)
end

---2つのチャットの関係を読むのに必要なものを揃える（どちらかがチャットでなければ nil）
---@param from_bufnr number
---@param to_bufnr number
---@return table? from_chat
---@return table? to_chat
---@return string? forward 送信先の表示パス
---@return string? backward 送信元の表示パス
local function relation(from_bufnr, to_bufnr)
  local from_chat, to_chat = resolve_chat(from_bufnr), resolve_chat(to_bufnr)
  if not from_chat or not to_chat then
    return nil
  end

  local from_path, to_path = vim.api.nvim_buf_get_name(from_bufnr), vim.api.nvim_buf_get_name(to_bufnr)
  if from_path == "" or to_path == "" then
    return nil
  end

  -- gitルートは1回だけ引く。`to_display_path` は既定で `get_root()` を呼び、それは
  -- キャッシュを持たない同期の `git rev-parse` 起動なので、2つのパスで2プロセスになる
  local git_root = Git.get_root()
  return from_chat, to_chat, Git.to_display_path(to_path, git_root), Git.to_display_path(from_path, git_root)
end

---逆向きの関係が既に記録されているか（＝この送信は報告・返答か）
---
---解決済みの4つを受け取る形にしてあるのは、`link` が同じものを手元に持っているため。
---公開の `M.direction` から呼ぶと `relation` がもう一度走り、`git rev-parse` が余分に起きる
---@param from_chat table
---@param to_chat table
---@param forward string 送信先の表示パス
---@param backward string 送信元の表示パス
---@return "Request"|"Report"
local function direction_from(from_chat, to_chat, forward, backward)
  if
    vim.tbl_contains(from_chat:get_frontmatter_list("orchestrated_by"), forward)
    or OrchestratedEntry.find(to_chat:get_frontmatter_list("orchestrated"), backward)
  then
    return "Report"
  end
  return "Request"
end

---この送信が配布か、報告・返答かを、記録済みの関係から決める
---
---「送信が報告か依頼か」を機構は判別できない（`completion_notifier` の同じ制約）が、
---「相手が既に自分のオーケストレータとして記録されている」なら向きだけは分かる。それが
---`link` の逆向きガードであり、配達セクションの見出し（`## Request` / `## Report`）が
---どちらになるかでもある。片側だけの記録でも報告と見なすのは `link` と同じ理由で、
---`link` は片肺の書き込みを許すため
---@param from_bufnr number
---@param to_bufnr number
---@return "Request"|"Report"
function M.direction(from_bufnr, to_bufnr)
  local from_chat, to_chat, forward, backward = relation(from_bufnr, to_bufnr)
  if not from_chat then
    return "Request"
  end
  return direction_from(from_chat, to_chat, forward, backward)
end

---A が B に指示を出した関係を両者の frontmatter に書く
---
---呼び出しは `ProgrammaticSender.send` より**前**に済ませること。
---`update_frontmatter_list` はバッファを直接編集するので、B の応答が始まってから書くと
---ストリーミングと競合する。
---@param from_bufnr number 送信元（オーケストレーター側）
---@param to_bufnr number 送信先（ワーカー側）
---@param task string? 何を頼んだか（自由テキスト1行、#696）。`from_chat`の`orchestrated`
---エントリにのみ書く — 子側には複製しない。既にリンクが張られている状態でも、渡された値が
---今の値と違えば「最新の指示」として書き換える
---@return boolean success
---@return string? error
function M.link(from_bufnr, to_bufnr, task)
  if from_bufnr == to_bufnr then
    return false, "A chat cannot orchestrate itself"
  end

  local from_chat, to_chat, forward, backward = relation(from_bufnr, to_bufnr)
  if not from_chat then
    -- 2つの理由（チャットバッファでない／ファイル名がない）を1つのメッセージに畳んである。
    -- 呼び出し元はどちらでも「リンクを記録できなかった」と警告するだけで、分岐はしない
    return false, "Both buffers must be vibing chat buffers with a file name"
  end

  -- スキルは `nvim_chat_create` と続く `nvim_chat_send_message` の両方に `from_bufnr` を渡すので、
  -- 同じリンクが2回書かれる。`update_frontmatter_list` は要素としては重複を弾くが、行の書き換えと
  -- `updated_at` の更新でバッファを modified にするため、そのあと両チャットの全文が書き直される
  local existing_entry, existing_task = OrchestratedEntry.find(from_chat:get_frontmatter_list("orchestrated"), forward)
  if existing_entry and vim.tbl_contains(to_chat:get_frontmatter_list("orchestrated_by"), backward) then
    -- 既にリンク済み。taskが新しく渡され、今の値と違うなら置き換える（「最新の指示」）。
    -- 正本はこの1エントリだけなので、書き換えもここ1箇所で完結する
    if task and task ~= "" and task ~= existing_task then
      from_chat:update_frontmatter_list("orchestrated", existing_entry, "remove")
      if from_chat:update_frontmatter_list("orchestrated", OrchestratedEntry.encode(forward, task), "add") then
        FileManager.save_buffer(from_bufnr)
      end
    end
    return true, nil
  end

  -- 逆向きの関係が既にあるなら、この送信は**報告か返答**であって新しい配下関係ではない。
  --
  -- 「送信が報告か依頼か」を機構は判別できない（`completion_notifier` の同じ制約）が、
  -- 「相手が既に自分のオーケストレータとして記録されている」なら向きだけは分かる。それが
  -- 無いと、押し出し型の報告（#643）が届くたびにここが逆向きのリンクを書き、親の
  -- `orchestrated_by` に自分のワーカーが並ぶ。frontmatter は木ではなくペアの二重記録になり、
  -- `cli_command_builder` はその `orchestrated_by` からシステムプロンプトを組むので、親が
  -- 「終わったら自分のワーカーに報告しろ」と指示される。実際に3チャットで再現したもの。
  --
  -- 片側だけでも逆向きが記録されていれば報告と見なす（`link` は片肺の書き込みを許すので、
  -- 両側揃うことを前提にはできない）。代償として A⇄B の相互オーケストレーションは
  -- 記録できないが、それは循環であって支持する形ではない
  if direction_from(from_chat, to_chat, forward, backward) == "Report" then
    return true, nil
  end

  -- 戻り値を捨ててはいけない。`update_frontmatter_list` は frontmatter の閉じ `---` が
  -- 先頭100行に収まらないと false を返す（長い permission 配列を持つチャットで現実に起きる）。
  -- 捨てると、このモジュールが防ぐために存在している「黙って関係が残らない」がそのまま起きる
  local wrote_forward = from_chat:update_frontmatter_list("orchestrated", OrchestratedEntry.encode(forward, task), "add")
  local wrote_back = to_chat:update_frontmatter_list("orchestrated_by", backward, "add")

  -- `update_frontmatter_list` はバッファにしか書かない。リネーム同期はディスクを読むので、
  -- ここで保存しないとリンクは「次に何かの理由で保存されるまで」存在しないことになる。
  -- 送信元は `:VibingChat` の性質上まだ一度も保存されていないことがあり、その窓がいちばん
  -- 長い（＝1ターン目に投げた相手が改名されるとリンクが片方向に腐る）
  -- 保存は書き込みの成否を見る**前**に、無条件で行う。片方だけ書けた状態でも、書けた側は
  -- ディスクに残さなければならない（片肺でもリネーム同期は残った側で動く、というのが
  -- このモジュールの設計方針）。成否チェックで先に return すると、書き込みに成功した
  -- バッファが modified のまま一度も保存されず、呼び出し元は警告するだけで続行するので
  -- 誰も気づかない
  local saved_from = FileManager.save_buffer(from_bufnr)
  local saved_to = FileManager.save_buffer(to_bufnr)

  if not (wrote_forward and wrote_back) then
    return false,
      string.format(
        "Could not record the orchestration link (%s side)",
        not wrote_forward and "orchestrator" or "worker"
      )
  end
  if not (saved_from and saved_to) then
    return false, "Wrote the orchestration link but could not save both chat files"
  end

  return true, nil
end

---`link` を呼び、失敗しても警告だけして続行する
---
---「リンクは記録であって、失敗が送信を止める理由にはならない」は送信経路2つ（即配達と
---キュー配達）に共通の方針だったので、方針と文言をここに1つ置く。2箇所に散らしておくと、
---片方だけ直した日に食い違う。`rpc/handlers/chat.lua` は作成時点の別文言を使うので通さない
---@param from_bufnr number
---@param to_bufnr number
---@param task string?
---@return boolean success
function M.link_or_warn(from_bufnr, to_bufnr, task)
  local ok, err = M.link(from_bufnr, to_bufnr, task)
  if not ok then
    require("vibing.core.utils.notify").warn(
      string.format("Could not link chats %d -> %d: %s", from_bufnr, to_bufnr, err or "unknown"),
      "Orchestration"
    )
  end
  return ok
end

return M
