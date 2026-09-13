---@class Vibing.Chat.WorktreeBinding
---worktreeへ入る操作を見つけたら、そのターンの終わりにチャットの `working_dir` を書く。
---
---`working_dir` が空のままだと、worktreeの中で何行書き換えても `### Modified Files` は
---**0件**になる。ツリースナップショットの基準が親リポジトリのままで、`.vibing/worktrees/` は
---そこでは無視対象だからである（実測: 同じターンが `working_dir` を worktree に向けるだけで
---0件・patchなし → 2件・361バイトのpatchになる）。
---
---スキルの手順書に「frontmatterを更新すること」と書いてあるだけでは、書かれないターンが出る。
---だから手順ではなくここで書く。
---
---判定は **操作の前後で `git worktree list` を比べる** だけ。増えた1本がそのターンで作られた
---worktreeで、コマンドの綴りには一切依存しない（`worktree_scan` を参照）。
local M = {}

local Git = require("vibing.core.utils.git")
local Scan = require("vibing.application.chat.worktree_scan")

---@class Vibing.WorktreeBinding.Pending
---@field before table<string, boolean> 操作前に存在したworktreeの絶対パス
---@field cwd string|nil そのチャットのcwd
---@field enter string|nil `EnterWorktree` が名指しした既存worktree
---@field exiting boolean `ExitWorktree` が呼ばれたか

---@type table<string, Vibing.WorktreeBinding.Pending>
local pending = {}

---PreToolUseから呼ぶ。ツールが走る **前** のworktree一覧を押さえる
---@param handle_id string|nil
---@param cwd string|nil そのチャットのcwd
---@param tool_name string
---@param tool_input table
function M.observe(handle_id, cwd, tool_name, tool_input)
  if not handle_id or handle_id == "" then
    return
  end
  local kind, path = Scan.classify(tool_name, tool_input)
  if not kind then
    return
  end

  local entry = pending[handle_id]
  if not entry then
    -- 一覧を押さえるのは最初の1回だけ。2回目以降に取り直すと、1つ目の操作で増えた分が
    -- 「元からあった」側に回ってしまう
    entry = { before = Scan.list(cwd), cwd = cwd, exiting = false }
    pending[handle_id] = entry
  end

  if kind == "enter" then
    entry.exiting = false
    -- 上書きであって `path or entry.enter` ではない。同じターンで `path` 指定の後に `name`
    -- 指定が来たら、前のパスを引きずると新しく作られた方を無視してしまう。nilに戻せば
    -- 一覧の前後差が拾う
    entry.enter = path
  elseif kind == "exit" then
    entry.exiting = true
    entry.enter = nil
  end
end

---@param handle_id string|nil
function M.clear(handle_id)
  if handle_id then
    pending[handle_id] = nil
  end
end

---そのターンで入ったworktreeの絶対パスを決める
---@param entry Vibing.WorktreeBinding.Pending
---@return string|nil abs
---@return string|nil ambiguous 複数増えていて決められなかったときの説明
local function landed_on(entry)
  if entry.enter then
    return (vim.fn.fnamemodify(entry.enter, ":p"):gsub("/$", "")), nil
  end

  local added = {}
  for path in pairs(Scan.list(entry.cwd)) do
    if not entry.before[path] then
      table.insert(added, path)
    end
  end
  if #added == 1 then
    return added[1], nil
  end
  if #added > 1 then
    table.sort(added)
    return nil, table.concat(added, ", ")
  end
  return nil, nil
end

---`ExitWorktree` の後始末。**今の `working_dir` がworktreeを指しているときだけ** 外す。
---無条件に消すと、ユーザーが自分で別の目的に設定した値まで巻き込む
---@param chat table
---@param entry Vibing.WorktreeBinding.Pending
---@return nil
local function unbind(chat, entry)
  local current = (chat:parse_frontmatter() or {}).working_dir
  if not current or current == "" or current == "." then
    return nil
  end

  local abs = Git.resolve_working_dir(current, Git.get_root(nil))
  if not abs or not entry.before[abs] then
    return nil
  end
  if chat:update_frontmatter("working_dir", nil) then
    vim.notify("[vibing] This chat left the worktree and runs at the repository root again.", vim.log.levels.INFO)
  end
  return nil
end

---ターンの終わりに呼ぶ。**差分を出し終えてから** でなければならない。
---フォールバック経路の `base_dir` はfrontmatterを今読むので、先に書き換えると、このターンの
---退避（旧cwd基準）と基準ディレクトリ（新cwd）が食い違う
---@param handle_id string|nil
---@param bufnr number|nil
---@return string|nil written 書き込んだ `working_dir`
function M.resolve(handle_id, bufnr)
  local entry = handle_id and pending[handle_id] or nil
  M.clear(handle_id)
  if not entry or not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return nil
  end

  local chat = require("vibing.presentation.chat.view").get_chat_buffer(bufnr)
  if not chat then
    return nil
  end
  if entry.exiting then
    return unbind(chat, entry)
  end

  local abs, ambiguous = landed_on(entry)
  if ambiguous then
    vim.notify(
      "[vibing] This turn created more than one worktree (" .. ambiguous .. "); "
        .. "set this chat's working_dir by hand to pick the one it should run in.",
      vim.log.levels.WARN
    )
    return nil
  end
  if not abs or vim.fn.isdirectory(abs) ~= 1 then
    return nil
  end

  -- `working_dir` はNeovimのcwdのgitルートからの相対パスとして読み戻される
  -- （`ChatBuffer:get_cwd` → `Git.resolve_working_dir` が引数なしで `get_root()` を呼ぶ）。
  -- 書く側も同じ基準で計算しないと、worktreeの中から見たルートで相対化してしまう
  local rel = Git.get_relative_path(abs, Git.get_root(nil))
  if not rel or rel == "." then
    return nil
  end
  if (chat:parse_frontmatter() or {}).working_dir == rel then
    return nil
  end
  if not chat:update_frontmatter("working_dir", rel) then
    return nil
  end

  vim.notify("[vibing] This chat now runs in " .. rel, vim.log.levels.INFO)
  return rel
end

return M
