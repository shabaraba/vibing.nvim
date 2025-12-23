-- Tests for vibing.adapters.base module

describe("vibing.adapters.base", function()
  local Adapter
  local mock_config

  before_each(function()
    package.loaded["vibing.adapters.base"] = nil
    Adapter = require("vibing.adapters.base")

    mock_config = {
      agent = {
        default_mode = "code",
        default_model = "sonnet",
      },
    }
  end)

  describe("new", function()
    it("should create adapter instance", function()
      local adapter = Adapter:new(mock_config)
      assert.is_not_nil(adapter)
      assert.equals("base", adapter.name)
    end)

    it("should store config reference", function()
      local adapter = Adapter:new(mock_config)
      assert.equals(mock_config, adapter.config)
    end)

    it("should initialize job_id as nil", function()
      local adapter = Adapter:new(mock_config)
      assert.is_nil(adapter.job_id)
    end)
  end)

  describe("execute", function()
    it("should throw error in base class", function()
      local adapter = Adapter:new(mock_config)
      assert.has_error(function()
        adapter:execute("test prompt", {})
      end, "execute() must be implemented by subclass")
    end)
  end)

  describe("stream", function()
    it("should throw error in base class", function()
      local adapter = Adapter:new(mock_config)
      local on_chunk = function() end
      local on_done = function() end
      assert.has_error(function()
        adapter:stream("test prompt", {}, on_chunk, on_done)
      end, "stream() must be implemented by subclass")
    end)
  end)

  describe("build_command", function()
    it("should throw error in base class", function()
      local adapter = Adapter:new(mock_config)
      assert.has_error(function()
        adapter:build_command("test prompt", {})
      end, "build_command() must be implemented by subclass")
    end)
  end)

  describe("cancel", function()
    it("should return false when no job running", function()
      local adapter = Adapter:new(mock_config)
      local result = adapter:cancel()
      assert.is_false(result)
    end)

    it("should stop job and return true when job exists", function()
      local adapter = Adapter:new(mock_config)
      adapter.job_id = 12345

      local result = adapter:cancel()
      assert.is_true(result)
      assert.is_nil(adapter.job_id)
    end)

    it("should clear job_id after canceling", function()
      local adapter = Adapter:new(mock_config)
      adapter.job_id = 99999
      adapter:cancel()
      assert.is_nil(adapter.job_id)
    end)
  end)

  describe("supports", function()
    it("should return false for any feature in base class", function()
      local adapter = Adapter:new(mock_config)
      assert.is_false(adapter:supports("streaming"))
      assert.is_false(adapter:supports("tools"))
      assert.is_false(adapter:supports("any_feature"))
    end)
  end)

  describe("inheritance", function()
    it("should support subclassing pattern", function()
      local SubAdapter = setmetatable({}, { __index = Adapter })
      SubAdapter.__index = SubAdapter

      function SubAdapter:new(config)
        local instance = Adapter.new(self, config)
        instance.name = "sub"
        return instance
      end

      local sub = SubAdapter:new(mock_config)
      assert.equals("sub", sub.name)
      assert.is_not_nil(sub.config)
    end)

    it("should allow overriding methods", function()
      local SubAdapter = setmetatable({}, { __index = Adapter })
      SubAdapter.__index = SubAdapter

      function SubAdapter:new(config)
        local instance = Adapter.new(self, config)
        return instance
      end

      function SubAdapter:supports(feature)
        return feature == "streaming"
      end

      local sub = SubAdapter:new(mock_config)
      assert.is_true(sub:supports("streaming"))
      assert.is_false(sub:supports("other"))
    end)
  end)
end)
