-- Tests for vibing.infrastructure.rpc.comm_dir

describe("vibing.infrastructure.rpc.comm_dir", function()
  local CommDir
  local saved_env
  local saved_registry_env
  local registry_dir

  before_each(function()
    package.loaded["vibing.infrastructure.rpc.comm_dir"] = nil
    CommDir = require("vibing.infrastructure.rpc.comm_dir")
    saved_env = vim.env[CommDir.ENV_VAR]
    vim.env[CommDir.ENV_VAR] = nil

    -- Starting the server below registers an instance; keep that out of the shared registry.
    saved_registry_env = vim.env.VIBING_INSTANCES_DIR
    registry_dir = vim.fn.tempname() .. "/vibing-instances"
    vim.env.VIBING_INSTANCES_DIR = registry_dir
  end)

  after_each(function()
    vim.env[CommDir.ENV_VAR] = saved_env
    pcall(vim.fn.delete, registry_dir, "rf")
    vim.env.VIBING_INSTANCES_DIR = saved_registry_env
  end)

  it("uses the override when it is set", function()
    vim.env[CommDir.ENV_VAR] = "/tmp/some-private-dir"
    assert.equals("/tmp/some-private-dir", CommDir.path())
  end)

  it("ignores an empty override", function()
    vim.env[CommDir.ENV_VAR] = ""
    assert.is_not.equals("", CommDir.path())
  end)

  it("keys the directory on the RPC port when the server is listening", function()
    local server = require("vibing.infrastructure.rpc.server")
    local tmp = vim.loop.new_tcp()
    tmp:bind("127.0.0.1", 0)
    local free_port = tmp:getsockname().port
    tmp:close()

    local port = server.start(free_port)
    assert.is_true(port > 0)

    assert.equals("/tmp/vibing-hook-" .. tostring(port), CommDir.path())

    server.stop()
  end)

  it("stays per-process when there is no port, instead of collapsing to a shared path", function()
    local server = require("vibing.infrastructure.rpc.server")
    if server.is_running() then
      server.stop()
    end

    local path = CommDir.path()
    assert.equals("/tmp/vibing-hook-0-" .. tostring(vim.fn.getpid()), path)
    -- The whole point: two portless instances must not land on the same directory.
    assert.is_not.equals("/tmp/vibing-hook-0", path)
  end)

  it("creates the directory on ensure()", function()
    local dir = vim.fn.tempname() .. "/comm"
    vim.env[CommDir.ENV_VAR] = dir

    assert.equals(0, vim.fn.isdirectory(dir))
    assert.equals(dir, CommDir.ensure())
    assert.equals(1, vim.fn.isdirectory(dir))

    vim.fn.delete(dir, "rf")
  end)
end)
