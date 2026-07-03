-- tests/lua/infrastructure/workspace/counter_spec.lua
local Counter = require("vibing.infrastructure.workspace.counter")

local function init_tmp_git_repo()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  vim.fn.system(string.format("git -C %s init -q", vim.fn.shellescape(dir)))
  vim.fn.system(string.format("git -C %s config user.email test@example.com", vim.fn.shellescape(dir)))
  vim.fn.system(string.format("git -C %s config user.name test", vim.fn.shellescape(dir)))
  return dir
end

describe("vibing.infrastructure.workspace.counter", function()
  local repo
  local prev_cwd

  before_each(function()
    repo = init_tmp_git_repo()
    prev_cwd = vim.fn.getcwd()
    vim.cmd("cd " .. vim.fn.fnameescape(repo))
  end)

  after_each(function()
    vim.cmd("cd " .. vim.fn.fnameescape(prev_cwd))
    vim.fn.delete(repo, "rf")
  end)

  it("starts at 1 when no counter file exists", function()
    local n, err = Counter.next()
    assert.is_nil(err)
    assert.equals(1, n)
  end)

  it("increments on each call", function()
    local n1 = Counter.next()
    local n2 = Counter.next()
    local n3 = Counter.next()
    assert.equals(1, n1)
    assert.equals(2, n2)
    assert.equals(3, n3)
  end)

  it("persists the counter to .vibing/workspace/.counter", function()
    Counter.next()
    local path = Counter.get_counter_path()
    assert.equals(1, vim.fn.filereadable(path))
    assert.equals("1", vim.fn.readfile(path)[1])
  end)

  it("returns an error outside a git repository", function()
    vim.cmd("cd " .. vim.fn.fnameescape("/tmp"))
    -- /tmp itself might be inside a repo on some CI images; use a fresh non-repo dir instead
    local non_repo = vim.fn.tempname()
    vim.fn.mkdir(non_repo, "p")
    vim.cmd("cd " .. vim.fn.fnameescape(non_repo))

    local n, err = Counter.next()
    assert.is_nil(n)
    assert.is_not_nil(err)

    vim.fn.delete(non_repo, "rf")
  end)
end)
