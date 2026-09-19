---@class Vibing.Presentation.ChatStatus
---バッファ番号を、そのチャットが今どういう状態で止まっている（動いている）かに変換する
---
---オーケストレーター（`claude-plugin/skills/vibing-orchestrate`）がワーカーの進捗をポーリングするときの
---唯一の判定材料。本文から「最後のセクションがAssistantか」を推測する方法は、応答がエラーで
---終わった場合やツール実行だけで無言のまま進んでいる場合に誤判定するため使わない。
---
---「実行中か」と「なぜ止まったか」を1つの語彙に畳む presentation 側の合成であって、事実そのもの
---ではない。事実は `ChatBuffer:is_responding()` と `ChatBuffer:get_stop_reason()` が持っていて、
---`completion_notifier` の発火判定は後者を直接読む（この語彙を経由しない）。
local M = {}

---バッファのチャット実行状態を取得する
---
---`idle` は「リクエストが飛んでいない」だけを意味する。成功したかどうかは含まない —
---それを言えるのは、モデル自身がそう報告したときだけ。
---@param bufnr number バッファ番号（0はカレントバッファ）
---@return "responding"|"idle"|"waiting_approval"|"asked_question"|"error"|nil state vibing.nvimのチャットバッファでない場合はnil
function M.get(bufnr)
  if not bufnr or bufnr == 0 then
    bufnr = vim.api.nvim_get_current_buf()
  end
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return nil
  end

  local chat_buf = require("vibing.presentation.chat.view").get_chat_buffer(bufnr)
  if not chat_buf then
    return nil
  end

  -- `is_responding()` より**先**に見る。承認を kill せずに答えられるようになった時点で
  -- （#778）、承認待ちのターンは開いたままになった — つまり `is_responding()` は true を
  -- 返し続ける。順序が逆だと、承認待ちのチャットは最大 `approval_wait_sec` のあいだ
  -- `responding` を装い、オーケストレーターからは「まだ走っている」に見える。
  --
  -- 読むのは `_stop_reason` ではなく「実際にフックが1つ以上ブロックされているか」。
  -- `_stop_reason` は次の送信まで前のターンの値が残るので、先に読むと本当に走っている
  -- ターンを承認待ちと誤報する。保留レジストリは答えが出た瞬間に空になるので古くならない
  if require("vibing.infrastructure.rpc.pending_approvals").has_for_chat(bufnr) then
    return "waiting_approval"
  end

  if chat_buf:is_responding() then
    return "responding"
  end

  -- 停止理由は「実行中でない」ときにしか意味を持たないので、`is_responding()` の後に読む
  return chat_buf:get_stop_reason() or "idle"
end

---いまこのチャットで答えを待っている承認の一覧
---
---**通知ではなくクエリで渡す。** 承認は1ターンに複数、並列に立つ（実測: フック3本が0.54秒差で
---重なる）ので、オーケストレーターは `nvim_chat_answer_approval` にどれへの答えかを渡す必要が
---あり、その id をどこかで得なければならない。
---
---通知に載せないのは、**通知がスナップショットだから**。3件の id を載せて配っても、相手が
---動く頃には1件が期限切れ、1件がユーザーに答えられている、が普通に起きる。「完了検出はテキスト
---推測ではなくステータスフィールド」と同じ理由で、状態はその瞬間に問い合わせる。
---
---**バッファの `<!-- vibing:req=... -->` を読ませるのも同じ理由で採らない。** あのマーカーは
---`<CR>` の帰属解決のためのもので、機械の入力源ではない（それはテキスト推測になる）。
---@param bufnr number
---@return {request_id: string, tool: string, expired: boolean?}[] 承認待ちでなければ空
function M.pending_approvals(bufnr)
  if not bufnr or bufnr == 0 then
    bufnr = vim.api.nvim_get_current_buf()
  end
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return {}
  end

  local chat_buf = require("vibing.presentation.chat.view").get_chat_buffer(bufnr)
  if not chat_buf or type(chat_buf.get_pending_approvals) ~= "function" then
    return {}
  end

  local summary = {}
  for _, entry in ipairs(chat_buf:get_pending_approvals()) do
    table.insert(summary, {
      request_id = entry.request_id,
      tool = entry.tool,
      -- 期限切れも載せる。消さずに印を付けて残す方針なので、バッファには見えている。
      -- 隠すと「見えているのに status に無い」になり、答えられない理由が分からなくなる
      expired = entry.expired or nil,
    })
  end
  return summary
end

---`pending_approvals` の、JSONに載せる形
---
---空リストではなく nil を返すのは、載ったときの見え方のため: `[]` は「承認待ちだが中身が無い」
---と読めてしまう。載っていなければ「承認待ちではない」で曖昧さがない。
---
---両方のRPCハンドラ（`nvim_chat_list` と `nvim_get_buffer`）が欲しいのはこちらの形だけなので、
---変換は語彙を持つこのモジュールに置く。片方のハンドラに置くと、もう片方がそれを呼ぶために
---ハンドラ同士の依存ができる
---@param bufnr number
---@return table[]?
function M.pending_approvals_or_nil(bufnr)
  local pending = M.pending_approvals(bufnr)
  if #pending == 0 then
    return nil
  end
  return pending
end

return M
