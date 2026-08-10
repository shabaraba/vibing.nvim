describe("context manager", function()
  local Manager = require("vibing.application.context.manager")
  local Collector = require("vibing.infrastructure.context.collector")
  local config = require("vibing.config")

  local original_collect_buffers
  local original_options

  before_each(function()
    original_collect_buffers = Collector.collect_buffers
    original_options = config.options
    Collector.collect_buffers = function()
      return { "@file:auto.lua" }
    end
    Manager.manual_contexts = { "@file:manual.lua" }
  end)

  after_each(function()
    Collector.collect_buffers = original_collect_buffers
    config.options = original_options
    Manager.manual_contexts = {}
  end)

  describe("format_for_display", function()
    it("includes auto-collected buffers when chat.auto_context is true", function()
      config.options = { chat = { auto_context = true } }

      local display = Manager.format_for_display()

      assert.is_truthy(display:find("manual.lua", 1, true))
      assert.is_truthy(display:find("auto.lua", 1, true))
    end)

    it("omits auto-collected buffers when chat.auto_context is false", function()
      config.options = { chat = { auto_context = false } }

      local display = Manager.format_for_display()

      assert.is_truthy(display:find("manual.lua", 1, true))
      assert.is_nil(display:find("auto.lua", 1, true))
    end)

    it("falls back to auto context when setup() has not run", function()
      config.options = nil

      local display = Manager.format_for_display()

      assert.is_truthy(display:find("auto.lua", 1, true))
    end)
  end)
end)
