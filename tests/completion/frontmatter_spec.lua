local frontmatter_source = require("vibing.application.completion.sources.frontmatter")
local frontmatter_provider = require("vibing.infrastructure.completion.providers.frontmatter")

describe("Frontmatter completion", function()
  describe("Enum fields", function()
    it("should detect mode field trigger", function()
      local ctx = frontmatter_source.get_trigger_context("mode: ", 6)
      assert.is_not_nil(ctx)
      assert.are.equal("frontmatter_enum", ctx.trigger)
      assert.are.equal("mode", ctx.field)
      assert.are.equal("", ctx.query)
      assert.are.equal(7, ctx.start_col)
    end)

    it("should detect mode field with partial value", function()
      local ctx = frontmatter_source.get_trigger_context("mode: co", 8)
      assert.is_not_nil(ctx)
      assert.are.equal("frontmatter_enum", ctx.trigger)
      assert.are.equal("mode", ctx.field)
      assert.are.equal("co", ctx.query)
    end)

    it("should detect model field trigger", function()
      local ctx = frontmatter_source.get_trigger_context("model: ", 7)
      assert.is_not_nil(ctx)
      assert.are.equal("frontmatter_enum", ctx.trigger)
      assert.are.equal("model", ctx.field)
    end)

    it("should detect permissions_mode field trigger", function()
      local ctx = frontmatter_source.get_trigger_context("permissions_mode: ", 18)
      assert.is_not_nil(ctx)
      assert.are.equal("frontmatter_enum", ctx.trigger)
      assert.are.equal("permissions_mode", ctx.field)
    end)

    it("should detect permission_mode field trigger (without 's')", function()
      local ctx = frontmatter_source.get_trigger_context("permission_mode: ", 17)
      assert.is_not_nil(ctx)
      assert.are.equal("frontmatter_enum", ctx.trigger)
      assert.are.equal("permissions_mode", ctx.field) -- Normalized
    end)

    it("should detect mode: with trailing space", function()
      local ctx = frontmatter_source.get_trigger_context("mode: ", 6)
      assert.is_not_nil(ctx)
      assert.are.equal("frontmatter_enum", ctx.trigger)
      assert.are.equal("mode", ctx.field)
      assert.are.equal("", ctx.query)
    end)

    it("should get mode enum values", function()
      local items = frontmatter_provider.get_enum_values("mode")
      assert.are.equal(4, #items)
      assert.are.equal("auto", items[1].word)
      assert.are.equal("plan", items[2].word)
      assert.are.equal("code", items[3].word)
      assert.are.equal("explore", items[4].word)
    end)

    it("should get model enum values", function()
      local items = frontmatter_provider.get_enum_values("model")
      assert.are.equal(3, #items)
      assert.are.equal("sonnet", items[1].word)
      assert.are.equal("opus", items[2].word)
      assert.are.equal("haiku", items[3].word)
    end)

    it("should get permissions_mode enum values", function()
      local items = frontmatter_provider.get_enum_values("permissions_mode")
      assert.are.equal(3, #items)
      assert.are.equal("default", items[1].word)
      assert.are.equal("acceptEdits", items[2].word)
      assert.are.equal("bypassPermissions", items[3].word)
    end)

    it("should filter candidates by query", function()
      local ctx = frontmatter_source.get_trigger_context("mode: pl", 9)
      local items = frontmatter_source.get_candidates_sync(ctx)
      -- "pl" matches both "plan" and "explore"
      assert.are.equal(2, #items)
      local words = vim.tbl_map(function(item)
        return item.word
      end, items)
      assert.is_true(vim.tbl_contains(words, "plan"))
      assert.is_true(vim.tbl_contains(words, "explore"))
    end)
  end)

  describe("Tool list fields", function()
    it("should detect list item trigger", function()
      -- Simulate being on a line "  - Re" under permissions_allow
      vim.api.nvim_buf_set_lines(0, 0, -1, false, {
        "---",
        "permissions_allow:",
        "  - Re",
      })
      vim.api.nvim_win_set_cursor(0, { 3, 6 })

      local line = "  - Re"
      local col = 6
      local ctx = frontmatter_source.get_trigger_context(line, col)

      assert.is_not_nil(ctx)
      assert.are.equal("frontmatter_tool", ctx.trigger)
      assert.are.equal("permissions_allow", ctx.field)
      assert.are.equal("Re", ctx.query)
    end)

    it("should get tool names", function()
      local items = frontmatter_provider.get_tool_names()
      assert.is_true(#items > 0)

      -- Check some expected tools
      local tool_names = vim.tbl_map(function(item)
        return item.word
      end, items)
      assert.is_true(vim.tbl_contains(tool_names, "Read"))
      assert.is_true(vim.tbl_contains(tool_names, "Edit"))
      assert.is_true(vim.tbl_contains(tool_names, "Write"))
      assert.is_true(vim.tbl_contains(tool_names, "Bash"))
      assert.is_true(vim.tbl_contains(tool_names, "Bash("))
    end)

    it("should filter tools by query", function()
      vim.api.nvim_buf_set_lines(0, 0, -1, false, {
        "---",
        "permissions_allow:",
        "  - Re",
      })
      vim.api.nvim_win_set_cursor(0, { 3, 6 })

      local line = "  - Re"
      local col = 6
      local ctx = frontmatter_source.get_trigger_context(line, col)
      local items = frontmatter_source.get_candidates_sync(ctx)

      -- Should have Read and other tools containing "Re"
      assert.is_true(#items > 0)
      local has_read = false
      for _, item in ipairs(items) do
        if item.word == "Read" then
          has_read = true
        end
      end
      assert.is_true(has_read)
    end)
  end)

  describe("Command pattern fields", function()
    it("should detect Bash(pattern) trigger", function()
      vim.api.nvim_buf_set_lines(0, 0, -1, false, {
        "---",
        "permissions_ask:",
        "  - Bash(rm",
      })
      vim.api.nvim_win_set_cursor(0, { 3, 12 })

      local line = "  - Bash(rm"
      local col = 12
      local ctx = frontmatter_source.get_trigger_context(line, col)

      assert.is_not_nil(ctx)
      assert.are.equal("frontmatter_pattern", ctx.trigger)
      assert.are.equal("Bash", ctx.tool)
      assert.are.equal("rm", ctx.query)
    end)

    it("should detect Bash( immediately after opening paren", function()
      vim.api.nvim_buf_set_lines(0, 0, -1, false, {
        "---",
        "permissions_ask:",
        "  - Bash(",
      })
      -- Cursor on '(' (col=8)
      vim.api.nvim_win_set_cursor(0, { 3, 8 })

      local line = "  - Bash("
      local col = 8
      local ctx = frontmatter_source.get_trigger_context(line, col)

      assert.is_not_nil(ctx)
      assert.are.equal("frontmatter_pattern", ctx.trigger)
      assert.are.equal("Bash", ctx.tool)
      assert.are.equal("", ctx.query)
      assert.are.equal(9, ctx.start_col) -- Position after '('
    end)

    it("should get Bash command patterns", function()
      local items = frontmatter_provider.get_command_patterns("Bash")
      assert.is_true(#items > 0)

      -- Check some expected patterns
      local pattern_names = vim.tbl_map(function(item)
        return item.word
      end, items)
      assert.is_true(vim.tbl_contains(pattern_names, "rm:*"))
      assert.is_true(vim.tbl_contains(pattern_names, "sudo:*"))
      assert.is_true(vim.tbl_contains(pattern_names, "git:*"))
    end)

    it("should filter patterns by query", function()
      vim.api.nvim_buf_set_lines(0, 0, -1, false, {
        "---",
        "permissions_ask:",
        "  - Bash(rm",
      })
      vim.api.nvim_win_set_cursor(0, { 3, 12 })

      local line = "  - Bash(rm"
      local col = 12
      local ctx = frontmatter_source.get_trigger_context(line, col)
      local items = frontmatter_source.get_candidates_sync(ctx)

      -- Should have "rm:*"
      assert.is_true(#items > 0)
      local has_rm = false
      for _, item in ipairs(items) do
        if item.word == "rm:*" then
          has_rm = true
        end
      end
      assert.is_true(has_rm)
    end)

    it("should complete empty pattern", function()
      vim.api.nvim_buf_set_lines(0, 0, -1, false, {
        "---",
        "permissions_ask:",
        "  - Bash(",
      })
      vim.api.nvim_win_set_cursor(0, { 3, 10 })

      local line = "  - Bash("
      local col = 10
      local ctx = frontmatter_source.get_trigger_context(line, col)
      local items = frontmatter_source.get_candidates_sync(ctx)

      -- Should return all patterns when query is empty
      assert.is_true(#items > 5)
    end)

    it("should complete patterns for Bash without parentheses", function()
      vim.api.nvim_buf_set_lines(0, 0, -1, false, {
        "---",
        "permissions_ask:",
        "  - Bash",
      })
      vim.api.nvim_win_set_cursor(0, { 3, 8 })

      local line = "  - Bash"
      local col = 8
      local ctx = frontmatter_source.get_trigger_context(line, col)

      assert.is_not_nil(ctx)
      assert.are.equal("frontmatter_pattern", ctx.trigger)
      assert.are.equal("Bash", ctx.tool)
      assert.are.equal("", ctx.query)

      local items = frontmatter_source.get_candidates_sync(ctx)
      -- Should return all Bash patterns
      assert.is_true(#items > 5)
      -- Verify some patterns are included
      local has_rm = false
      local has_git = false
      for _, item in ipairs(items) do
        if item.word == "rm:*" then
          has_rm = true
        end
        if item.word == "git:*" then
          has_git = true
        end
      end
      assert.is_true(has_rm)
      assert.is_true(has_git)
    end)
  end)
end)
