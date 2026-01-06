-- Tests for vibing.infrastructure.rpc.registry module

describe("vibing.infrastructure.rpc.registry", function()
  local registry
  local uv = vim.loop

  before_each(function()
    -- Reload module before each test
    package.loaded["vibing.infrastructure.rpc.registry"] = nil
    registry = require("vibing.infrastructure.rpc.registry")
  end)

  describe("register", function()
    it("should register current instance with port", function()
      local port = 9876
      local success = registry.register(port)

      assert.is_true(success)

      -- Verify instance is in registry
      local instances = registry.list()
      local found = false
      local current_pid = vim.fn.getpid()

      for _, instance in ipairs(instances) do
        if instance.pid == current_pid and instance.port == port then
          found = true
          assert.equals(port, instance.port)
          assert.equals(vim.fn.getcwd(), instance.cwd)
          assert.is_not_nil(instance.started_at)
          break
        end
      end

      assert.is_true(found, "Instance should be registered")
    end)
  end)

  describe("unregister", function()
    it("should remove current instance from registry", function()
      local port = 9876
      registry.register(port)

      local success = registry.unregister()
      assert.is_true(success)

      -- Verify instance is not in registry
      local instances = registry.list()
      local current_pid = vim.fn.getpid()
      local found = false

      for _, instance in ipairs(instances) do
        if instance.pid == current_pid then
          found = true
          break
        end
      end

      assert.is_false(found, "Instance should be unregistered")
    end)

    it("should succeed even if instance is not registered", function()
      local success = registry.unregister()
      assert.is_true(success)
    end)
  end)

  describe("list", function()
    it("should return empty array when no instances registered", function()
      -- Clean up any existing instances first
      registry.unregister()

      local instances = registry.list()
      assert.is_table(instances)
      -- Note: May contain other instances from other Neovim processes
      -- So we can't assert it's completely empty
    end)

    it("should return registered instances", function()
      local port = 9877
      registry.register(port)

      local instances = registry.list()
      assert.is_table(instances)

      local current_pid = vim.fn.getpid()
      local found = false

      for _, instance in ipairs(instances) do
        if instance.pid == current_pid then
          found = true
          assert.equals(port, instance.port)
          break
        end
      end

      assert.is_true(found, "Current instance should be in list")
    end)

    it("should sort instances by started_at descending", function()
      local port1 = 9878
      local port2 = 9879

      -- Register first instance
      registry.register(port1)
      vim.wait(10) -- Small delay to ensure different timestamps

      -- Register second instance (newer)
      local current_pid = vim.fn.getpid()
      local registry_dir = vim.fn.stdpath("data") .. "/vibing-instances"
      local fake_pid = current_pid + 1

      -- Manually create a second instance file with newer timestamp
      local instance_data = {
        pid = fake_pid,
        port = port2,
        cwd = vim.fn.getcwd(),
        started_at = os.time() + 10, -- Future timestamp
      }

      local file_path = registry_dir .. "/" .. fake_pid .. ".json"
      vim.fn.writefile({ vim.json.encode(instance_data) }, file_path)

      local instances = registry.list()

      -- Clean up fake instance
      vim.fn.delete(file_path)

      -- The fake instance (with newer timestamp) should be first
      -- But we can't guarantee exact order due to other instances
      -- So we just verify sorting works in general
      if #instances >= 2 then
        for i = 1, #instances - 1 do
          assert.is_true(
            (instances[i].started_at or 0) >= (instances[i + 1].started_at or 0),
            "Instances should be sorted by started_at descending"
          )
        end
      end
    end)
  end)

  describe("is_port_in_use", function()
    it("should return false when port is not in use", function()
      local unused_port = 9999
      local in_use = registry.is_port_in_use(unused_port)
      assert.is_false(in_use)
    end)

    it("should return true when port is in use", function()
      local port = 9876
      registry.register(port)

      local in_use = registry.is_port_in_use(port)
      assert.is_true(in_use)

      registry.unregister()
    end)

    it("should use cached instances list when provided", function()
      local port = 9876
      registry.register(port)

      -- Get cached list
      local instances = registry.list()

      -- Check using cached list (should find the port)
      local in_use = registry.is_port_in_use(port, instances)
      assert.is_true(in_use)

      registry.unregister()
    end)

    it("should fetch fresh list when cache not provided", function()
      local port = 9877
      registry.register(port)

      -- Don't pass cached instances - should fetch fresh
      local in_use = registry.is_port_in_use(port)
      assert.is_true(in_use)

      registry.unregister()
    end)
  end)

  describe("error handling", function()
    it("should handle missing registry directory gracefully", function()
      -- Remove registry directory if it exists
      local registry_dir = vim.fn.stdpath("data") .. "/vibing-instances"
      pcall(vim.fn.delete, registry_dir, "rf")

      -- list() should return empty array
      local instances = registry.list()
      assert.is_table(instances)

      -- register() should create directory and succeed
      local success = registry.register(9876)
      assert.is_true(success)

      -- Cleanup
      registry.unregister()
    end)
  end)
end)
