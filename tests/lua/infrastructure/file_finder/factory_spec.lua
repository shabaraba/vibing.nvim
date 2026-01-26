-- Tests for vibing.infrastructure.file_finder.factory module

describe("vibing.infrastructure.file_finder.factory", function()
  local factory

  before_each(function()
    package.loaded["vibing.infrastructure.file_finder.factory"] = nil
    package.loaded["vibing.infrastructure.file_finder.find_command"] = nil
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

    it("should return find_command on macOS/Linux", function()
      local finder = factory.get_finder()
      -- On macOS/Linux, should prefer find_command
      assert.equals("find_command", finder.name)
    end)

    it("should return scandir when force_fallback is true", function()
      local finder = factory.get_finder(true)
      assert.equals("scandir", finder.name)
    end)

    it("should cache finder instance", function()
      local finder1 = factory.get_finder()
      local finder2 = factory.get_finder()
      assert.are.equal(finder1, finder2)
    end)

    it("should not use cache when force_fallback changes", function()
      local finder1 = factory.get_finder()
      local finder2 = factory.get_finder(true)
      assert.are_not.equal(finder1.name, finder2.name)
    end)
  end)

  describe("reset_cache", function()
    it("should clear cached finder", function()
      local finder1 = factory.get_finder()
      factory.reset_cache()
      local finder2 = factory.get_finder()
      -- After reset, should create new instance (but same type)
      assert.equals(finder1.name, finder2.name)
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
      assert.is_true(name == "find_command" or name == "scandir")
    end)

    it("should return scandir when force_fallback is used", function()
      factory.get_finder(true)
      local name = factory.get_current_finder_name()
      assert.equals("scandir", name)
    end)
  end)
end)
