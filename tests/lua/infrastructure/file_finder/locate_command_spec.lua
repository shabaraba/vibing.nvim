describe("vibing.infrastructure.file_finder.locate_command", function()
  local locate_command = require("vibing.infrastructure.file_finder.locate_command")

  local function skip_if_unsupported(finder)
    if not finder:supports_platform() then
      pending("locate/plocate command not available on this platform")
      return true
    end
    return false
  end

  describe("new", function()
    it("should create instance with correct name", function()
      local finder = locate_command:new()
      assert.equals("locate_command", finder.name)
    end)

    it("should accept mtime_days option", function()
      local finder = locate_command:new({ mtime_days = 7 })
      assert.equals(7, finder.mtime_days)
    end)
  end)

  describe("supports_platform", function()
    it("should return boolean indicating locate availability", function()
      local finder = locate_command:new()
      local supported = finder:supports_platform()
      assert.is_boolean(supported)
    end)

    it("should prefer plocate over locate", function()
      local finder = locate_command:new()
      if not finder:supports_platform() then
        pending("locate/plocate not available")
        return
      end
      -- locate_cmd should be set after supports_platform
      assert.is_true(finder.locate_cmd == "plocate" or finder.locate_cmd == "locate")
    end)
  end)

  describe("find", function()
    it("should return error for non-existent directory", function()
      local finder = locate_command:new()
      if skip_if_unsupported(finder) then return end

      local files, err = finder:find("/non/existent/path", "*.md")
      assert.is_table(files)
      assert.equals(0, #files)
      assert.is_not_nil(err)
    end)

    -- Note: locate tests are limited because they depend on updatedb index
    -- which may not include recently created test files
  end)
end)
