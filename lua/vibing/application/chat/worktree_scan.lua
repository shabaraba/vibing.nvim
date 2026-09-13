---@class Vibing.Chat.WorktreeScan
---「今どのworktreeがあるか」と「このツール呼び出しはworktreeに触るか」。
---`worktree_binding` が決める方針とは別に、gitとツールの綴りについての知識だけを持つ。
local M = {}

---@param cwd string|nil
---@return table<string, boolean> worktreeの絶対パス
function M.list(cwd)
  local opts = { text = true }
  if cwd and cwd ~= "" then
    opts.cwd = cwd
  end
  local ok, result = pcall(function()
    return vim.system({ "git", "worktree", "list", "--porcelain" }, opts):wait()
  end)
  if not ok or not result or result.code ~= 0 then
    return {}
  end

  local paths = {}
  for line in (result.stdout or ""):gmatch("[^\r\n]+") do
    local path = line:match("^worktree (.+)$")
    if path then
      paths[path] = true
    end
  end
  return paths
end

---このツール呼び出しがworktreeに触るものか
---
---`EnterWorktree` は `path` で既存のworktreeに入り、`name` で新しく作る
---（`.claude/worktrees/<name>`。vibing.nvim自身の `.vibing/worktrees/` とは別系統）。
---前者は今すぐ分かり、後者はまだ存在しないので一覧の前後差に任せる。
---@param tool_name string
---@param tool_input table
---@return "enter"|"exit"|"create"|nil kind
---@return string|nil path `enter` のときだけ、名指しされた既存worktree
function M.classify(tool_name, tool_input)
  if type(tool_input) ~= "table" then
    return nil, nil
  end

  if tool_name == "EnterWorktree" then
    return "enter", type(tool_input.path) == "string" and tool_input.path or nil
  end
  if tool_name == "ExitWorktree" then
    return "exit", nil
  end
  if tool_name == "Bash" and type(tool_input.command) == "string" then
    -- シェルは読まない。`-b` の有無・引用符・変数展開で崩れるので、綴りの一致は
    -- 「一覧を前後で比べる価値があるか」の入口判定にしか使わない。空振りしても
    -- `git worktree list` が2回走って「増えていない」と分かるだけで、何も書かない
    if tool_input.command:match("worktree%s+add") then
      return "create", nil
    end
  end
  return nil, nil
end

return M
