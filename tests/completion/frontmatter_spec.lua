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

    it("should detect permission_mode field trigger", function()
      local ctx = frontmatter_source.get_trigger_context("permission_mode: ", 17)
      assert.is_not_nil(ctx)
      assert.are.equal("frontmatter_enum", ctx.trigger)
      assert.are.equal("permission_mode", ctx.field)
    end)

    it("should not complete the legacy plural permissions_mode key", function()
      local ctx = frontmatter_source.get_trigger_context("permissions_mode: ", 18)
      assert.is_nil(ctx)
    end)

    it("should detect mode: with trailing space", function()
      local ctx = frontmatter_source.get_trigger_context("mode: ", 6)
      assert.is_not_nil(ctx)
      assert.are.equal("frontmatter_enum", ctx.trigger)
      assert.are.equal("mode", ctx.field)
      assert.are.equal("", ctx.query)
    end)

    it("should get model enum values via get_model_values", function()
      local items = frontmatter_provider.get_model_values("claude")
      assert.are.equal(4, #items)
      assert.are.equal("haiku", items[1].word)
      assert.are.equal("sonnet", items[2].word)
      assert.are.equal("opus", items[3].word)
      assert.are.equal("fable", items[4].word)
    end)

    it("should offer every registered backend in agent enum values", function()
      -- Derived from agents.lua, so a new backend appears here without touching the provider.
      local items = frontmatter_provider.get_enum_values("agent")
      assert.are.equal(4, #items)
      assert.are.equal("claude", items[1].word)
      assert.are.equal("codex", items[2].word)
      assert.are.equal("copilot", items[3].word)
      assert.are.equal("grok", items[4].word)
    end)

    it("should get copilot model values via get_model_values", function()
      local items = frontmatter_provider.get_model_values("copilot")
      assert.are.equal(9, #items)
      assert.are.equal("auto", items[1].word)
      assert.are.equal("claude-sonnet-5", items[2].word)
      assert.are.equal("Enum", items[1].kind)
    end)

    it("should fall back to claude models for an unknown agent", function()
      local items = frontmatter_provider.get_model_values("nonexistent")
      assert.are.equal(4, #items)
      assert.are.equal("haiku", items[1].word)
    end)

    it("should get permission_mode enum values", function()
      local items = frontmatter_provider.get_enum_values("permission_mode")
      assert.are.equal(6, #items)
      assert.are.equal("default", items[1].word)
      assert.are.equal("acceptEdits", items[2].word)
      assert.are.equal("plan", items[3].word)
      assert.are.equal("auto", items[4].word)
      assert.are.equal("dontAsk", items[5].word)
      assert.are.equal("bypassPermissions", items[6].word)
    end)

    it("should filter candidates by query", function()
      local ctx = frontmatter_source.get_trigger_context("permission_mode: accept", 23)
      local items = frontmatter_source.get_candidates_sync(ctx)
      -- "accept" matches only "acceptEdits"
      assert.are.equal(1, #items)
      assert.are.equal("acceptEdits", items[1].word)
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

  describe("_read_frontmatter_agent", function()
    local buf
    local previous

    ---frontmatterを現在のバッファとして開く(`_read_frontmatter_agent`はそこを読む)
    ---@param lines string[]
    local function open(lines)
      previous = vim.api.nvim_get_current_buf()
      buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
      vim.api.nvim_set_current_buf(buf)
    end

    after_each(function()
      if previous and vim.api.nvim_buf_is_valid(previous) then
        vim.api.nvim_set_current_buf(previous)
      end
      if buf and vim.api.nvim_buf_is_valid(buf) then
        vim.api.nvim_buf_delete(buf, { force = true })
      end
    end)

    it("reads the agent from a short frontmatter", function()
      open({ "---", "agent: codex", "---", "# Vibing Chat" })
      assert.are.equal("codex", frontmatter_source._read_frontmatter_agent())
    end)

    it("reads an agent pushed past the old 30-line window", function()
      -- `agent:` sits above the permission lists in serializer order today, but a
      -- long enough list ahead of it used to push it out of the window and the
      -- completion silently fell back to claude's models.
      local lines = { "---", "permissions_allow:" }
      for i = 1, 60 do
        table.insert(lines, "  - perm" .. i)
      end
      table.insert(lines, "agent: codex")
      table.insert(lines, "---")
      open(lines)

      assert.are.equal("codex", frontmatter_source._read_frontmatter_agent())
    end)

    it("returns nil when the frontmatter names no agent", function()
      open({ "---", "session_id: abc", "---", "# Vibing Chat" })
      assert.is_nil(frontmatter_source._read_frontmatter_agent())
    end)

    it("returns nil when the frontmatter never closes", function()
      open({ "---", "agent: codex" })
      assert.is_nil(frontmatter_source._read_frontmatter_agent())
    end)

    it("does not read an agent line from the body", function()
      open({ "---", "session_id: abc", "---", "agent: codex" })
      assert.is_nil(frontmatter_source._read_frontmatter_agent())
    end)
  end)
end)
