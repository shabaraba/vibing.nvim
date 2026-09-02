---@class Vibing.Presentation.OrchestrationTreeRenderer
---`orchestration_tree` が組んだ木を、罫線付きの行の並びにする。
---
---状態（`responding` / `idle` / ...）を貼るのはここで、木を組む側ではない。あちらが読むのは
---frontmatter だけ＝ディスクに残る事実で、状態は走行中のバッファにしか無い。混ぜると
---「開いていないチャットの状態」という答えのない欄ができる
local M = {}

local ChatStatus = require("vibing.presentation.chat.modules.chat_status")

---@param node Vibing.Application.OrchestrationTree.Node
---@param current_abs string? いま開いているチャットの実体パス
---@return string
local function label(node, current_abs)
  local parts = { node.path }

  if node.bufnr then
    table.insert(parts, string.format("(buffer %d)", node.bufnr))
    -- バッファはあるのに状態が無いのは、チャットとしてアタッチされていないとき。`idle` と
    -- 書くとポーリングできる相手に見えるので、区別できる語を出す
    table.insert(parts, "[" .. (ChatStatus.get(node.bufnr) or "not attached") .. "]")
  else
    table.insert(parts, "[not open]")
  end

  if node.repeated then
    table.insert(parts, "(shown above)")
  end

  -- 木が数ノードを超えると、自分がどこにいるのかがパスの並びからは読み取れなくなる
  if current_abs and node.abs == current_abs then
    table.insert(parts, "←")
  end

  return table.concat(parts, " ")
end

---@param node Vibing.Application.OrchestrationTree.Node?
---@param current_abs string? 印を付けるノードの実体パス
---@return string[] lines
function M.render(node, current_abs)
  if not node then
    return {}
  end

  local lines = { label(node, current_abs) }

  local function walk(current, prefix)
    local last_index = #current.children
    for i, child in ipairs(current.children) do
      local is_last = i == last_index
      table.insert(lines, prefix .. (is_last and "└─ " or "├─ ") .. label(child, current_abs))
      walk(child, prefix .. (is_last and "   " or "│  "))
    end
  end

  walk(node, "")
  return lines
end

return M
