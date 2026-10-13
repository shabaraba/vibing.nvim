-- Tests for vibing.infrastructure.adapter.modules.tool_display

local tool_display = require("vibing.infrastructure.adapter.modules.tool_display")

describe("tool_display.resolve_marker", function()
  it("returns the marker configured for the tool", function()
    assert.equals("▶", tool_display.resolve_marker("Task", { Task = "▶", default = "⏺" }))
  end)

  it("falls back to the configured default for an unlisted tool", function()
    assert.equals("⏺", tool_display.resolve_marker("Read", { Task = "▶", default = "⏺" }))
  end)

  it("falls back to the built-in default when no markers are configured", function()
    assert.equals("⏺", tool_display.resolve_marker("Read", nil))
    assert.equals("⏺", tool_display.resolve_marker("Read", {}))
  end)
end)

describe("config validation of ui.tools.markers", function()
  local config = require("vibing.config")

  local function markers_after_setup(tool_markers)
    config.setup({
      ui = {
        tools = {
          markers = tool_markers,
        },
      },
    })
    return config.get().ui.tools.markers
  end

  after_each(function()
    config.setup({})
  end)

  it("keeps plain string markers", function()
    local markers = markers_after_setup({ Bash = "💻", default = "⏺" })
    assert.equals("💻", markers.Bash)
    assert.equals("⏺", markers.default)
  end)

  for _, invalid in ipairs({ "", 42, { default = "💻" }, { patterns = { ["^npm"] = "📦" } } }) do
    it("rejects invalid or obsolete marker values", function()
      assert.has_error(function()
        markers_after_setup({ Bash = invalid })
      end)
    end)
  end
end)
