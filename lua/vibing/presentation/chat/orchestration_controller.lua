---@class Vibing.Presentation.OrchestrationController
---オーケストレーション網そのものを見る・止めるコマンドのPresentation層Controller。
---
---`controller.lua` から分けてあるのは、あちらが「1つのチャットを開く・畳む・要約する」ための
---入り口で、こちらの対象が**チャットの集合**だから。共有するのは下の `target_path` だけで、
---それはこの2コマンドにしか要らない
local M = {}

local notify = require("vibing.core.utils.notify")

---コマンドが対象にするチャットの表示パスを決める
---
---引数があればそれ、無ければ「いまのチャット」。後者の解決順は `:VibingCancel` と同じで、
---カーソルがチャット外にあるときは直近のチャットに落ちる
---@param args string?
---@return string? display_path 解決できなければ nil（呼び出し元が警告する）
local function target_path(args)
  if args and vim.trim(args) ~= "" then
    return vim.trim(args)
  end

  local view = require("vibing.presentation.chat.view")
  local chat_buf = view.get_current() or view._current_buffer
  if not chat_buf then
    return nil
  end

  return require("vibing.application.chat.orchestration_tree").display_path_of(chat_buf:get_buffer())
end

---@param args string?
function M.handle_tree(args)
  local path = target_path(args)
  if not path then
    return notify.warn("Not in a chat buffer. Pass a chat file path to draw its tree.")
  end

  local OrchestrationTree = require("vibing.application.chat.orchestration_tree")

  -- 描くのは常に木の全体。オーケストレーターの1階層下しか見えないのでは、中間ノードを
  -- 持つ木で「どこで止まっているか」が分からず、可視化の意味がない
  local root = OrchestrationTree.build(OrchestrationTree.root_of(path))
  if not root then
    return notify.warn("Could not resolve a chat at " .. path)
  end

  local Renderer = require("vibing.presentation.chat.modules.orchestration_tree_renderer")
  local lines = Renderer.render(root, OrchestrationTree.abs_of(path))

  if #lines == 1 and #root.children == 0 then
    return notify.info("This chat orchestrates no other chats:\n" .. lines[1])
  end
  notify.info("Orchestration tree:\n" .. table.concat(lines, "\n"))
end

---@param args string?
function M.handle_cancel_tree(args)
  local path = target_path(args)
  if not path then
    return notify.warn("Not in a chat buffer. Pass a chat file path to cancel its subtree.")
  end

  -- 根まで遡らないのが `handle_tree` との違い。指したノードから下だけを止める、が
  -- このコマンドの意味で、上まで巻き込むと「自分の親も道連れ」になる
  local cancelled, visited = require("vibing.application.chat.use_cases.cancel_tree").execute(path)

  if #cancelled == 0 then
    return notify.info(string.format("Nothing was running in this subtree (%d chat(s))", visited))
  end

  local names = {}
  for _, node in ipairs(cancelled) do
    table.insert(names, string.format("  %s (buffer %d)", node.path, node.bufnr))
  end
  notify.info(
    string.format("Cancelled %d of %d chat(s) in this subtree:\n%s", #cancelled, visited, table.concat(names, "\n"))
  )
end

return M
