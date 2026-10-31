-- Tests for vibing.infrastructure.rpc.server module

-- Ask the OS for a currently-free ephemeral port so tests don't collide with
-- real vibing.nvim instances (or each other) parked on the hardcoded 9876-9925 range.
local function find_free_port()
  local tmp = vim.loop.new_tcp()
  tmp:bind("127.0.0.1", 0)
  local port = tmp:getsockname().port
  tmp:close()
  return port
end

local ENV_REGISTRY_DIR = require("vibing.infrastructure.rpc.registry").ENV_REGISTRY_DIR

describe("vibing.infrastructure.rpc.server", function()
  local server
  local registry
  local CommDir
  local base_port
  local registry_dir
  local saved_env
  local saved_comm_dir
  local private_comm_root

  before_each(function()
    -- Private registry directory: the default under stdpath("data") is shared machine-wide, so
    -- the fake instance files written below would collide with the parallel plenary jobs.
    saved_env = vim.env[ENV_REGISTRY_DIR]
    registry_dir = vim.fn.tempname() .. "/vibing-instances"
    vim.env[ENV_REGISTRY_DIR] = registry_dir

    -- Reload modules before each test
    package.loaded["vibing.infrastructure.rpc.server"] = nil
    package.loaded["vibing.infrastructure.rpc.registry"] = nil
    package.loaded["vibing.infrastructure.rpc.comm_dir"] = nil
    server = require("vibing.infrastructure.rpc.server")
    registry = require("vibing.infrastructure.rpc.registry")
    CommDir = require("vibing.infrastructure.rpc.comm_dir")
    base_port = find_free_port()

    -- Not `/tmp/vibing-hook-<port>`. Plenary runs one Neovim per spec file, and another file's
    -- hook_cleanup treats a comm directory whose port is absent from the shared registry as stale
    -- and deletes it. The permission bits are a property of SessionToken.install, exercised on this
    -- private path; production still uses for_port when the override is unset.
    saved_comm_dir = vim.env[CommDir.ENV_VAR]
    private_comm_root = vim.fn.tempname()
    vim.fn.mkdir(private_comm_root, "p")
    vim.env[CommDir.ENV_VAR] = private_comm_root .. "/comm"
  end)

  after_each(function()
    -- Clean up server if running
    if server.is_running() then
      server.stop()
    end
    pcall(vim.fn.delete, private_comm_root, "rf")
    pcall(vim.fn.delete, registry_dir, "rf")
    vim.env[ENV_REGISTRY_DIR] = saved_env
    vim.env[CommDir.ENV_VAR] = saved_comm_dir
  end)

  describe("start", function()
    it("should start server on base port when available", function()
      local port = server.start(base_port)

      assert.is_true(port >= base_port)
      assert.is_true(port < base_port + 50)
      assert.is_true(server.is_running())
      assert.equals(port, server.get_port())

      server.stop()
    end)

    it("should try next port when base port is in use", function()
      -- Start first server on base port
      local first_port = server.start(base_port)
      assert.is_true(server.is_running())

      -- Start second server (should use next port)
      package.loaded["vibing.infrastructure.rpc.server"] = nil
      local server2 = require("vibing.infrastructure.rpc.server")
      local second_port = server2.start(base_port)

      assert.is_true(second_port > first_port)
      assert.is_true(server2.is_running())

      server.stop()
      server2.stop()
    end)

    it("should return 0 when all ports are exhausted", function()
      -- This test is difficult to implement without blocking 10 ports
      -- We'll test the logic by mocking registry
      -- Mock registry.is_port_in_use to return true for all ports
      local original_is_port_in_use = registry.is_port_in_use
      registry.is_port_in_use = function()
        return true
      end

      -- Mock registry.list to return empty (simulate all ports blocked by OS)
      local original_list = registry.list
      registry.list = function()
        return {}
      end

      local port = server.start(base_port)

      -- Restore original functions
      registry.is_port_in_use = original_is_port_in_use
      registry.list = original_list

      -- Should fail to find available port
      assert.equals(0, port)
      assert.is_false(server.is_running())
    end)

    it("should register instance after successful start", function()
      local port = server.start(base_port)

      assert.is_true(port > 0)

      -- Check registry
      local instances = registry.list()
      local current_pid = vim.fn.getpid()
      local found = false

      for _, instance in ipairs(instances) do
        if instance.pid == current_pid and instance.port == port then
          found = true
          break
        end
      end

      assert.is_true(found, "Instance should be registered after server start")

      server.stop()
    end)

    it("should return current port if already running", function()
      local first_port = server.start(base_port)
      local second_port = server.start(base_port)

      assert.equals(first_port, second_port)

      server.stop()
    end)

    it("should skip ports in registry (cached instances)", function()
      -- Stub list() rather than writing an instance file: a file needs a PID, and list() now
      -- correctly prunes entries whose process is gone, so a fabricated PID would be dropped
      -- before port allocation ever saw it.
      local original_list = registry.list
      registry.list = function()
        return { { pid = vim.fn.getpid(), port = base_port, cwd = vim.fn.getcwd(), started_at = os.time() } }
      end

      local port = server.start(base_port)
      registry.list = original_list

      assert.is_true(port > base_port, "Should skip registered port")

      server.stop()
    end)
  end)

  describe("stop", function()
    it("should stop running server", function()
      server.start(base_port)
      assert.is_true(server.is_running())

      server.stop()
      assert.is_false(server.is_running())
      assert.is_nil(server.get_port())
    end)

    it("should unregister instance after stop", function()
      local port = server.start(base_port)
      local current_pid = vim.fn.getpid()

      server.stop()

      -- Check registry
      local instances = registry.list()
      local found = false

      for _, instance in ipairs(instances) do
        if instance.pid == current_pid and instance.port == port then
          found = true
          break
        end
      end

      assert.is_false(found, "Instance should be unregistered after server stop")
    end)

    it("should handle stop when server is not running", function()
      assert.is_false(server.is_running())
      -- Should not throw error
      server.stop()
      assert.is_false(server.is_running())
    end)
  end)

  describe("get_port", function()
    it("should return nil when server is not running", function()
      assert.is_nil(server.get_port())
    end)

    it("should return current port when server is running", function()
      local port = server.start(base_port)

      assert.equals(port, server.get_port())

      server.stop()
    end)
  end)

  describe("is_running", function()
    it("should return false when server is not running", function()
      assert.is_false(server.is_running())
    end)

    it("should return true when server is running", function()
      server.start(base_port)
      assert.is_true(server.is_running())
      server.stop()
    end)
  end)

  describe("TOCTOU race condition handling", function()
    it("should handle bind failure gracefully and try next port", function()
      -- This is tested implicitly by the "try next port" test above
      -- The atomic bind() operation ensures TOCTOU is handled correctly

      local port = server.start(base_port)

      -- Even if registry check passes, bind will fail atomically if port is taken
      -- Server should try next port automatically
      assert.is_true(port >= base_port)
      assert.is_true(server.is_running())

      server.stop()
    end)
  end)

  describe("Performance optimization", function()
    it("should cache instance list during port allocation", function()
      -- This is difficult to test directly, but we can verify behavior
      -- The optimization means registry.list() is called once, not 10 times

      -- Stub list() for the same reason as the test above: five instances would need five live
      -- PIDs, and the registry keys files by PID so they cannot be faked on disk.
      local instances = {}
      for i = 0, 4 do
        table.insert(instances, {
          pid = vim.fn.getpid(),
          port = base_port + i,
          cwd = vim.fn.getcwd(),
          started_at = os.time(),
        })
      end
      local original_list = registry.list
      registry.list = function()
        return instances
      end

      -- Start server - should skip the first 5 registered ports
      local port = server.start(base_port)
      registry.list = original_list

      assert.is_true(port >= base_port + 5, "Should skip all registered ports")

      server.stop()
    end)
  end)

  describe("session token", function()
    local handlers
    local original_execute

    local function settle()
      local done = false
      vim.schedule(function()
        done = true
      end)
      assert.is_true(vim.wait(1000, function()
        return done
      end, 10), "event loop did not drain")
    end

    --- One newline-delimited request. Returns the decoded response line.
    local function rpc(port, payload)
      local client = assert(vim.loop.new_tcp())
      local chunks = {}
      local done = false
      local connect_err
      client:connect("127.0.0.1", port, function(err)
        if err then
          connect_err = err
          done = true
          return
        end
        client:read_start(function(read_err, data)
          if read_err or not data then
            done = true
            if not client:is_closing() then
              client:close()
            end
            return
          end
          table.insert(chunks, data)
          if table.concat(chunks):find("\n", 1, true) then
            client:read_stop()
            if not client:is_closing() then
              client:close()
            end
            done = true
          end
        end)
        client:write(vim.json.encode(payload) .. "\n")
      end)

      local waited = vim.wait(2000, function()
        return done
      end, 10)
      if not client:is_closing() then
        client:close()
      end
      assert.is_true(waited, "timed out waiting for an RPC response")
      assert.is_nil(connect_err)
      local line = table.concat(chunks):match("([^\n]*)\n")
      assert.is_not_nil(line, "response was not a single JSON line")
      return vim.json.decode(line)
    end

    local function read_token()
      local f = assert(io.open(CommDir.path() .. "/" .. CommDir.TOKEN_NAME, "r"))
      local token = f:read("*a")
      f:close()
      return token
    end

    before_each(function()
      handlers = require("vibing.infrastructure.rpc.handlers")
      original_execute = handlers.execute
    end)

    after_each(function()
      handlers.execute = original_execute
    end)

    it("rejects a request with no token before the handler runs", function()
      local port = server.start(base_port)
      local ran = false
      handlers.execute = function()
        ran = true
        return { ok = true }
      end

      local res = rpc(port, { id = 1, method = "execute", params = { command = "echo pwned" } })
      settle()

      assert.is_false(ran)
      assert.equals("unauthorized", res.error)
      assert.is_nil(res.result)
    end)

    it("rejects a request with the wrong token before the handler runs", function()
      local port = server.start(base_port)
      local ran = false
      handlers.execute = function()
        ran = true
        return { ok = true }
      end

      local res = rpc(port, {
        id = 2,
        method = "execute",
        params = { command = "echo pwned" },
        token = "deadbeef",
      })
      settle()

      assert.is_false(ran)
      assert.equals("unauthorized", res.error)
      assert.is_nil(res.result)
      assert.is_nil(tostring(res.error):find("deadbeef", 1, true))
    end)

    it("runs the handler when the request carries the session token", function()
      local port = server.start(base_port)
      local token = read_token()
      local saw
      handlers.execute = function(params)
        saw = params
        return { ok = true }
      end

      local res = rpc(port, {
        id = 3,
        method = "execute",
        params = { command = "echo ok" },
        token = token,
      })

      assert.same({ command = "echo ok" }, saw)
      assert.is_nil(saw.token)
      assert.same({ ok = true }, res.result)
      assert.equals(3, res.id)
    end)

    it("creates the comm directory mode 0700 and private files even with umask 0", function()
      local ffi = require("ffi")
      pcall(ffi.cdef, "int umask(int mask);")
      local previous = ffi.C.umask(0)
      local ok, err = pcall(function()
        local port = server.start(base_port)
        assert.is_true(port > 0)
        local dir = CommDir.path()
        local dir_stat = assert(vim.loop.fs_lstat(dir))
        assert.equals("directory", dir_stat.type)
        assert.equals(tonumber("0700", 8), dir_stat.mode % 4096)

        local token_stat = assert(vim.loop.fs_lstat(dir .. "/" .. CommDir.TOKEN_NAME))
        assert.equals("file", token_stat.type)
        assert.equals(tonumber("0600", 8), token_stat.mode % 4096)

        local HookResponse = require("vibing.infrastructure.rpc.hook_response")
        HookResponse.write("perm-1", "deny", "no")
        local res_stat = assert(vim.loop.fs_lstat(dir .. "/perm-1.res"))
        assert.equals(tonumber("0600", 8), res_stat.mode % 4096)

        local token = read_token()
        local registry_files = vim.fn.glob(registry_dir .. "/*.json", false, true)
        assert.is_true(#registry_files > 0, "the running instance should be registered")
        for _, file in ipairs(registry_files) do
          local body = table.concat(vim.fn.readfile(file), "\n")
          assert.is_nil(body:find(token, 1, true), "registry file contains the session token")
        end
      end)
      ffi.C.umask(previous)
      assert.is_true(ok, tostring(err))
    end)

    it("does not write the token through a symlink at the comm path", function()
      local parent = vim.fn.tempname()
      vim.fn.mkdir(parent, "p")
      local target = parent .. "/target"
      vim.fn.mkdir(target, "p")
      local link = parent .. "/link"
      assert.is_true(vim.loop.fs_symlink(target, link))
      vim.env[CommDir.ENV_VAR] = link

      local ok, err = pcall(function()
        local port = server.start(base_port)
        assert.is_true(port > 0)
        assert.is_nil(vim.loop.fs_stat(target .. "/" .. CommDir.TOKEN_NAME))
        assert.is_nil(vim.loop.fs_lstat(link .. "/" .. CommDir.TOKEN_NAME))
      end)

      vim.fn.delete(parent, "rf")
      assert.is_true(ok, tostring(err))
    end)
  end)
end)
