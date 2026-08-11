-- Tests for vibing.infrastructure.adapter.modules.hook_cleanup

describe("hook_cleanup.cleanup_stale_dirs", function()
  local hook_cleanup
  local CommDir
  local registry
  local root
  local saved_comm_env
  local saved_registry_env
  local registry_dir

  ---Create a comm directory with a request file in it.
  ---@param name string basename under the fake /tmp root
  ---@return string dir
  local function make_dir(name)
    local dir = root .. "/" .. name
    vim.fn.mkdir(dir, "p")
    vim.fn.writefile({ "{}" }, dir .. "/req-1.req")
    return dir
  end

  ---@param dir string
  ---@return boolean
  local function exists(dir)
    return vim.fn.isdirectory(dir) == 1
  end

  before_each(function()
    package.loaded["vibing.infrastructure.adapter.modules.hook_cleanup"] = nil
    package.loaded["vibing.infrastructure.rpc.comm_dir"] = nil
    package.loaded["vibing.infrastructure.rpc.registry"] = nil
    hook_cleanup = require("vibing.infrastructure.adapter.modules.hook_cleanup")
    CommDir = require("vibing.infrastructure.rpc.comm_dir")
    registry = require("vibing.infrastructure.rpc.registry")

    -- Scan a private directory instead of the real /tmp, so the test cannot delete a
    -- developer's (or a parallel spec's) live comm directory.
    root = vim.fn.tempname() .. "/fake-tmp"
    vim.fn.mkdir(root, "p")
    CommDir.ROOT = root

    saved_comm_env = vim.env[CommDir.ENV_VAR]
    vim.env[CommDir.ENV_VAR] = nil

    saved_registry_env = vim.env[registry.ENV_REGISTRY_DIR]
    registry_dir = vim.fn.tempname() .. "/vibing-instances"
    vim.env[registry.ENV_REGISTRY_DIR] = registry_dir
  end)

  after_each(function()
    pcall(vim.fn.delete, root, "rf")
    pcall(vim.fn.delete, registry_dir, "rf")
    vim.env[CommDir.ENV_VAR] = saved_comm_env
    vim.env[registry.ENV_REGISTRY_DIR] = saved_registry_env
    package.loaded["vibing.infrastructure.rpc.comm_dir"] = nil
  end)

  it("removes a directory left behind by a dead session", function()
    local orphan = make_dir(CommDir.PREFIX .. "65001")

    hook_cleanup.cleanup_stale_dirs()

    assert.is_false(exists(orphan))
  end)

  it("keeps the directory of another instance that is still running", function()
    -- Register this process under a different port: registry.list() only returns live PIDs,
    -- so from cleanup's point of view this is another healthy Neovim.
    registry.register(65002)
    local live = make_dir(CommDir.PREFIX .. "65002")
    local orphan = make_dir(CommDir.PREFIX .. "65003")

    hook_cleanup.cleanup_stale_dirs()

    assert.is_true(exists(live), "a running instance's comm dir must survive")
    assert.equals(1, vim.fn.filereadable(live .. "/req-1.req"), "its in-flight request must survive")
    assert.is_false(exists(orphan))

    registry.unregister()
  end)

  it("removes a directory whose instance is still registered but no longer running", function()
    -- unregister() only runs on a clean exit, so a crashed/killed Neovim leaves its registry
    -- entry behind. Guarding on the registry must not turn that stale entry into a permanent
    -- reason to keep the comm directory -- otherwise /tmp accumulates forever.
    local dead_pid = 4000123
    vim.fn.mkdir(registry_dir, "p")
    vim.fn.writefile({
      vim.json.encode({ pid = dead_pid, port = 65010, cwd = vim.fn.getcwd(), started_at = os.time() }),
    }, registry_dir .. "/" .. dead_pid .. ".json")
    local crashed = make_dir(CommDir.PREFIX .. "65010")

    hook_cleanup.cleanup_stale_dirs()

    assert.is_false(exists(crashed))
  end)

  it("sweeps leftover files out of its own directory without removing it", function()
    local own = make_dir(CommDir.PREFIX .. "65004")
    vim.env[CommDir.ENV_VAR] = own

    hook_cleanup.cleanup_stale_dirs()

    assert.is_true(exists(own))
    assert.equals(0, vim.fn.filereadable(own .. "/req-1.req"))
  end)

  it("does not touch unrelated directories", function()
    local unrelated = make_dir("something-else")

    hook_cleanup.cleanup_stale_dirs()

    assert.is_true(exists(unrelated))
  end)
end)
