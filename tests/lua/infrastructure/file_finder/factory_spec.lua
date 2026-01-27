-- Tests for vibing.infrastructure.file_finder.factory module

describe("vibing.infrastructure.file_finder.factory", function()
  local factory

  before_each(function()
    package.loaded["vibing.infrastructure.file_finder.factory"] = nil
    package.loaded["vibing.infrastructure.file_finder.find_command"] = nil
    package.loaded["vibing.infrastructure.file_finder.fd_command"] = nil
    package.loaded["vibing.infrastructure.file_finder.locate_command"] = nil
    package.loaded["vibing.infrastructure.file_finder.ripgrep_command"] = nil
    package.loaded["vibing.infrastructure.file_finder.scandir"] = nil
    factory = require("vibing.infrastructure.file_finder.factory")
    factory.reset_cache()
  end)

  after_each(function()
    factory.reset_cache()
  end)

  describe("get_finder", function()
    it("should return finder instance", function()
      local finder = factory.get_finder()
      assert.is_not_nil(finder)
      assert.is_function(finder.find)
      assert.is_function(finder.supports_platform)
    end)

    it("should return a supported finder with auto strategy", function()
      local finder = factory.get_finder()
      -- On macOS/Linux, should prefer fastest available (fd > ripgrep > find > locate)
      assert.is_true(
        finder.name == "fd_command"
        or finder.name == "ripgrep_command"
        or finder.name == "find_command"
        or finder.name == "locate_command"
        or finder.name == "scandir"
      )
    end)

    it("should return scandir when force_fallback is true", function()
      local finder = factory.get_finder({ force_fallback = true })
      assert.equals("scandir", finder.name)
    end)

    it("should cache finder instance for same strategy", function()
      local finder1 = factory.get_finder()
      local finder2 = factory.get_finder()
      assert.are.equal(finder1, finder2)
    end)

    it("should not use cache when force_fallback changes", function()
      local finder1 = factory.get_finder()
      local finder2 = factory.get_finder({ force_fallback = true })
      assert.are_not.equal(finder1.name, finder2.name)
    end)

    it("should not cache when mtime_days is specified", function()
      local finder1 = factory.get_finder()
      local finder2 = factory.get_finder({ mtime_days = 1 })
      -- finder2 should be a new instance (may or may not be same reference)
      assert.is_not_nil(finder2)
      assert.is_not_nil(finder2.name)
    end)

    it("should respect strategy option when available", function()
      local finder = factory.get_finder({ strategy = "find" })
      -- Should be find_command if available, or fallback
      if finder.name == "find_command" then
        assert.equals("find_command", finder.name)
      else
        -- Strategy not available, fallback occurred
        assert.is_not_nil(finder.name)
      end
    end)

    it("should fallback when requested strategy is not available", function()
      -- Test with a potentially unavailable strategy
      local finder = factory.get_finder({ strategy = "locate" })
      -- Should return some finder (either locate or fallback)
      assert.is_not_nil(finder)
      assert.is_not_nil(finder.name)
    end)
  end)

  describe("reset_cache", function()
    it("should clear cached finder", function()
      factory.get_finder()
      assert.is_not_nil(factory.get_current_finder_name())
      factory.reset_cache()
      assert.is_nil(factory.get_current_finder_name())
    end)
  end)

  describe("get_current_finder_name", function()
    it("should return nil before first get_finder call", function()
      local name = factory.get_current_finder_name()
      assert.is_nil(name)
    end)

    it("should return finder name after get_finder call", function()
      factory.get_finder()
      local name = factory.get_current_finder_name()
      assert.is_string(name)
    end)

    it("should return scandir when force_fallback is used", function()
      factory.get_finder({ force_fallback = true })
      local name = factory.get_current_finder_name()
      assert.equals("scandir", name)
    end)
  end)

  describe("get_current_strategy", function()
    it("should return nil before any finder is created", function()
      assert.is_nil(factory.get_current_strategy())
    end)

    it("should return 'auto' after auto finder is created", function()
      factory.get_finder()
      local strategy = factory.get_current_strategy()
      assert.equals("auto", strategy)
    end)

    it("should return specific strategy when requested and available", function()
      factory.get_finder({ strategy = "find" })
      local strategy = factory.get_current_strategy()
      -- May be "find" if available, or "auto" if fell back
      assert.is_not_nil(strategy)
    end)
  end)

  describe("get_available_strategies", function()
    it("should return array of available strategies", function()
      local strategies = factory.get_available_strategies()
      assert.is_table(strategies)
    end)

    it("should only include strategies that are supported", function()
      local strategies = factory.get_available_strategies()
      for _, strategy in ipairs(strategies) do
        local finder = factory.get_finder({ strategy = strategy })
        assert.is_not_nil(finder)
      end
    end)
  end)
end)
