-- lua/vibing/infrastructure/workspace/manager.lua
---@class Vibing.Infrastructure.Workspace.Manager
---workspaceのライフサイクル（作成・一覧・完了）を担当するモジュール
local M = {}

local Git = require("vibing.core.utils.git")
local Counter = require("vibing.infrastructure.workspace.counter")
local Meta = require("vibing.infrastructure.workspace.meta")

---@return string?
local function get_workspace_base()
  local git_root = Git.get_root()
  if not git_root then
    return nil
  end
  return git_root .. "/.vibing/workspace"
end

---@param branch string
---@return boolean
local function is_valid_branch(branch)
  if not branch or branch == "" then
    return false
  end
  if branch:match("[/\\]") or branch:match("%.%.") then
    return false
  end
  return true
end

---@param branch string
---@param worktree_path string
---@return boolean success
---@return string? error
local function create_git_worktree(branch, worktree_path)
  local branches = vim.fn.systemlist("git branch --list " .. vim.fn.shellescape(branch))
  local branch_exists = branches and #branches > 0 and branches[1] ~= ""

  local cmd
  if branch_exists then
    cmd = string.format("git worktree add %s %s", vim.fn.shellescape(worktree_path), vim.fn.shellescape(branch))
  else
    cmd = string.format("git worktree add -b %s %s", vim.fn.shellescape(branch), vim.fn.shellescape(worktree_path))
  end

  local result = vim.fn.system(cmd)
  if vim.v.shell_error ~= 0 then
    return false, result
  end
  return true, nil
end

---@param worktree_path string
local function setup_environment(worktree_path)
  local git_root = Git.get_root()
  if not git_root then
    return
  end

  local items_to_copy = {
    ".gitignore",
    ".nvmrc",
    ".node-version",
    "package.json",
    "package-lock.json",
    "yarn.lock",
    "pnpm-lock.yaml",
    "tsconfig.json",
    "tsconfig.*.json",
    ".eslintrc*",
    ".prettierrc*",
    "jest.config.*",
    "vitest.config.*",
    ".editorconfig",
  }

  for _, item in ipairs(items_to_copy) do
    local matches = vim.fn.glob(git_root .. "/" .. item, false, true)
    for _, source in ipairs(matches) do
      local relative_path = source:sub(#git_root + 2)
      local dest = worktree_path .. "/" .. relative_path
      local dest_dir = vim.fn.fnamemodify(dest, ":h")
      if vim.fn.isdirectory(dest_dir) == 0 then
        vim.fn.mkdir(dest_dir, "p")
      end
      vim.fn.system(string.format("cp -rp %s %s", vim.fn.shellescape(source), vim.fn.shellescape(dest)))
    end
  end
end

---@param worktree_path string
local function setup_node_modules(worktree_path)
  local git_root = Git.get_root()
  if not git_root then
    return
  end

  local main_node_modules = git_root .. "/node_modules"
  if vim.fn.isdirectory(main_node_modules) == 1 then
    vim.fn.system(
      string.format(
        "ln -sf %s %s",
        vim.fn.shellescape(main_node_modules),
        vim.fn.shellescape(worktree_path .. "/node_modules")
      )
    )
  end
end

---@param description string
---@return string[]
function M.plan_template(description)
  return {
    "# " .. description,
    "",
    "## TODO",
    "",
    "- [ ] ",
    "",
    "## Notes",
    "",
  }
end

---@param branch string
---@param description string
---@return table? workspace
---@return string? error
function M.create(branch, description)
  if not is_valid_branch(branch) then
    return nil, "Invalid branch name: " .. tostring(branch)
  end

  local base = get_workspace_base()
  if not base then
    return nil, "Not in a git repository"
  end

  local number, counter_err = Counter.next()
  if not number then
    return nil, counter_err
  end

  local id = string.format("%04d-%s", number, branch)
  local dir = base .. "/active/" .. id

  if vim.fn.isdirectory(dir) == 1 then
    return nil, "Workspace directory already exists: " .. dir
  end

  vim.fn.mkdir(dir, "p")

  local worktree_path = dir .. "/worktree"
  local ok, git_err = create_git_worktree(branch, worktree_path)
  if not ok then
    vim.fn.delete(dir, "rf")
    return nil, "Failed to create git worktree: " .. tostring(git_err)
  end

  setup_environment(worktree_path)
  setup_node_modules(worktree_path)

  local meta_path = dir .. "/meta.yaml"
  Meta.write(meta_path, {
    workspace_id = id,
    branch = branch,
    created_at = os.date("%Y-%m-%dT%H:%M:%S"),
    description = description,
    chat_files = {},
  })

  local plan_path = dir .. "/plan.md"
  vim.fn.writefile(M.plan_template(description), plan_path)

  return {
    id = id,
    dir = dir,
    worktree_path = worktree_path,
    meta_path = meta_path,
    plan_path = plan_path,
  },
    nil
end

---@param status "active"|"done"
---@return table[]
function M.list(status)
  local base = get_workspace_base()
  if not base then
    return {}
  end

  local status_dir = base .. "/" .. status
  if vim.fn.isdirectory(status_dir) == 0 then
    return {}
  end

  local entries = {}
  local dirs = vim.fn.glob(status_dir .. "/*", false, true)
  table.sort(dirs)
  for _, dir in ipairs(dirs) do
    local meta_path = dir .. "/meta.yaml"
    local data = Meta.read(meta_path)
    if data then
      table.insert(entries, {
        id = data.workspace_id,
        branch = data.branch,
        description = data.description,
        dir = dir,
      })
    end
  end

  return entries
end

---@param workspace_id string
---@return table? workspace
function M.get(workspace_id)
  local base = get_workspace_base()
  if not base then
    return nil
  end

  for _, status in ipairs({ "active", "done" }) do
    local dir = base .. "/" .. status .. "/" .. workspace_id
    if vim.fn.isdirectory(dir) == 1 then
      local result = {
        id = workspace_id,
        dir = dir,
        status = status,
        meta_path = dir .. "/meta.yaml",
        plan_path = dir .. "/plan.md",
      }
      if status == "active" then
        result.worktree_path = dir .. "/worktree"
      end
      return result
    end
  end

  return nil
end

---@param workspace_id string
---@return boolean success
---@return string? error
function M.remove_worktree(workspace_id)
  local ws = M.get(workspace_id)
  if not ws or ws.status ~= "active" then
    return false, "Not an active workspace: " .. workspace_id
  end

  local cmd = string.format("git worktree remove %s", vim.fn.shellescape(ws.worktree_path))
  local result = vim.fn.system(cmd)
  if vim.v.shell_error ~= 0 then
    return false, result
  end
  return true, nil
end

---@param workspace_id string
---@return boolean success
---@return string? error
function M.move_to_done(workspace_id)
  local ws = M.get(workspace_id)
  if not ws or ws.status ~= "active" then
    return false, "Not an active workspace: " .. workspace_id
  end

  local base = get_workspace_base()
  local done_dir = base .. "/done"
  vim.fn.mkdir(done_dir, "p")

  local target = done_dir .. "/" .. workspace_id
  local result = vim.fn.rename(ws.dir, target)
  if result ~= 0 then
    return false, "Failed to move workspace to done: " .. ws.dir
  end
  return true, nil
end

---@param branch string
---@return boolean
function M.is_branch_merged(branch)
  local merged = vim.fn.systemlist("git branch --merged")
  for _, line in ipairs(merged) do
    if vim.trim(line):gsub("^%*%s*", "") == branch then
      return true
    end
  end
  return false
end

---@param plan_path string
---@return boolean
function M.plan_has_incomplete_todos(plan_path)
  if vim.fn.filereadable(plan_path) == 0 then
    return false
  end
  local lines = vim.fn.readfile(plan_path)
  for _, line in ipairs(lines) do
    if line:match("^%s*%-%s*%[%s*%]") then
      return true
    end
  end
  return false
end

return M
