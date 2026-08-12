describe("subagent_display", function()
  local display = require("vibing.infrastructure.adapter.modules.subagent_display")

  describe("format_buffer", function()
    it("indents every line under the rail", function()
      local out = display.format_buffer("explorer", "alpha\nbeta", false)
      assert.equals("  │ alpha\n  │ beta\n", out)
    end)

    it("labels every line when show_prefix is on", function()
      local out = display.format_buffer("explorer", "alpha\nbeta", true)
      assert.equals("  │ [explorer] alpha\n  │ [explorer] beta\n", out)
    end)

    it("falls back to a generic label when the type is missing", function()
      assert.equals("  │ [subagent] hi\n", display.format_buffer(nil, "hi", true))
      assert.equals("  │ [subagent] hi\n", display.format_buffer("", "hi", true))
    end)

    it("returns nothing for empty or whitespace-only text", function()
      assert.equals("", display.format_buffer("explorer", "", false))
      assert.equals("", display.format_buffer("explorer", "   \n\n", false))
      assert.equals("", display.format_buffer("explorer", nil, false))
    end)

    it("trims surrounding blank lines the CLI leaves on message boundaries", function()
      assert.equals("  │ hi\n", display.format_buffer("explorer", "\n\nhi\n\n", false))
    end)
  end)

  describe("get_cached_show_prefix", function()
    it("resolves once per stream context", function()
      local context = {}
      local first = display.get_cached_show_prefix(context)
      assert.equals(first, context._cached_show_prefix)
      assert.equals(first, display.get_cached_show_prefix(context))
    end)

    it("resolves to a boolean even with no config loaded", function()
      assert.equals("boolean", type(display.get_show_prefix()))
    end)
  end)
end)
