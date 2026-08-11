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

describe("config validation of ui.tool_markers", function()
  local config = require("vibing.config")

  local function markers_after_setup(tool_markers)
    config.setup({ ui = { tool_markers = tool_markers } })
    return config.get().ui.tool_markers
  end

  after_each(function()
    config.setup({})
  end)

  it("keeps plain string markers", function()
    local markers = markers_after_setup({ Bash = "💻", default = "⏺" })
    assert.equals("💻", markers.Bash)
    assert.equals("⏺", markers.default)
  end)

  it("drops an empty string marker so the default applies", function()
    assert.is_nil(markers_after_setup({ Bash = "" }).Bash)
  end)

  it("drops a marker that is not a string", function()
    assert.is_nil(markers_after_setup({ Bash = 42 }).Bash)
  end)

  it("flattens the legacy { default = ... } form to a string", function()
    assert.equals("💻", markers_after_setup({ Bash = { default = "💻" } }).Bash)
  end)

  it("drops the never-implemented patterns key instead of pretending it works", function()
    local markers = markers_after_setup({
      Bash = { default = "💻", patterns = { ["^npm"] = "📦" } },
    })
    assert.equals("💻", markers.Bash)
    -- Resolution only ever sees the tool name, so a pattern marker could never win.
    assert.equals("💻", tool_display.resolve_marker("Bash", markers))
  end)

  it("drops a legacy table with no usable default", function()
    assert.is_nil(markers_after_setup({ Bash = { patterns = { ["^npm"] = "📦" } } }).Bash)
  end)
end)
