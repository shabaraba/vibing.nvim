---@class Vibing.Application.Chat.UseCases.CancelTree
---1つのチャットを根として、そのサブツリー全体の走行中ターンをまとめて止める。
---
---扇状に配ったあとで方針が変わったとき、`:VibingCancel` をワーカーの数だけ繰り返すには、
---まずワーカーがどこにいるかを知らなければならない — 窓なしで作られているので画面には出ない。
---木は frontmatter が既に知っているので、そこから辿って止める。
local M = {}

local OrchestrationTree = require("vibing.application.chat.orchestration_tree")

---@param display_path string 根にするチャットの表示パス
---@return {path: string, bufnr: number}[] cancelled 実際に止めたチャット
---@return number visited 木に含まれていたチャットの数
function M.execute(display_path)
  local nodes = OrchestrationTree.flatten(OrchestrationTree.build(display_path))

  local targets = {}
  for _, node in ipairs(nodes) do
    -- `repeated` は同じチャットの2度目の登場なので、1度目で既に対象に入っている
    if node.bufnr and not node.repeated then
      table.insert(targets, node)
    end
  end

  -- **止める前に、木の全員ぶんの購読と配達待ちを捨てる。** `cancel_request` は
  -- `wrapped_on_done` を同期で呼び、それが `VibingResponseDone` → キューの drain に繋がるので、
  -- 残したまま順に止めると、止めたそばから木の別のノードが配達で再稼働する。
  -- 木の外側の親への watchdog 通知も、根のエッジごとここで落ちる — 止めたのは人間なので、
  -- 「ワーカーが黙って止まった、読みに行け」は事実に反する
  local CompletionNotifier = require("vibing.application.chat.completion_notifier")
  for _, node in ipairs(targets) do
    CompletionNotifier.forget(node.bufnr)
  end

  local view = require("vibing.presentation.chat.view")
  local cancelled = {}
  for _, node in ipairs(targets) do
    local chat_buf = view.get_chat_buffer(node.bufnr)
    if chat_buf and chat_buf:cancel_request() then
      table.insert(cancelled, node)
    end
  end

  return cancelled, #nodes
end

return M
