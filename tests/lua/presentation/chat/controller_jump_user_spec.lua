--- Unit coverage for the arithmetic behind :VibingChatJumpNextUser / :VibingChatJumpPrevUser.
--- tests/e2e/chat_jump_user_spec.lua drives the commands for real; this pins the edge cases that
--- would need one spawned Neovim instance each to reach through the command.
local Controller = require("vibing.presentation.chat.controller")

describe("controller User section jump", function()
  local buffers = {}

  local function scratch(lines)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    table.insert(buffers, buf)
    return buf
  end

  after_each(function()
    for _, buf in ipairs(buffers) do
      if vim.api.nvim_buf_is_valid(buf) then
        vim.api.nvim_buf_delete(buf, { force = true })
      end
    end
    buffers = {}
  end)

  describe("_collect_user_header_lines", function()
    it("finds every spelling of a User header a chat file can contain", function()
      -- Timestamped, legacy and unsent headers all have to count, or the jump silently skips
      -- whichever form the file happens to use.
      local buf = scratch({
        "---",
        "vibing.nvim: true",
        "---",
        "## User <!-- 2026-08-13 09:00:00 -->", -- 4
        "hello",
        "## Assistant <!-- 2026-08-13 09:00:01 -->",
        "hi",
        "## User", -- 8, legacy
        "again",
        "## Assistant",
        "sure",
        "## User <!-- unsent -->", -- 12
      })

      assert.same({ 4, 8, 12 }, Controller._collect_user_header_lines(buf))
    end)

    it("returns an empty list for a buffer with no User header", function()
      local buf = scratch({ "# Notes", "## Assistant", "nothing here" })
      assert.same({}, Controller._collect_user_header_lines(buf))
    end)
  end)

  describe("_resolve_jump_target", function()
    local headers = { 4, 8, 12 }

    it("moves to the header strictly after the cursor", function()
      assert.equals(4, Controller._resolve_jump_target(headers, 1, "next"))
      assert.equals(8, Controller._resolve_jump_target(headers, 4, "next"))
    end)

    it("moves to the header strictly before the cursor", function()
      assert.equals(8, Controller._resolve_jump_target(headers, 12, "prev"))
      assert.equals(4, Controller._resolve_jump_target(headers, 8, "prev"))
    end)

    it("does not offer the header the cursor already sits on", function()
      -- Otherwise the command is a no-op when invoked from a header and looks broken.
      assert.equals(8, Controller._resolve_jump_target(headers, 4, "next"))
      assert.equals(4, Controller._resolve_jump_target(headers, 8, "prev"))
    end)

    it("honours a count", function()
      assert.equals(12, Controller._resolve_jump_target(headers, 1, "next", 3))
      assert.equals(4, Controller._resolve_jump_target(headers, 12, "prev", 2))
    end)

    it("treats the command's countless default of 0 as 1", function()
      -- nvim_create_user_command{ count = 0 } passes 0 when the user typed no count.
      assert.equals(4, Controller._resolve_jump_target(headers, 1, "next", 0))
      assert.equals(8, Controller._resolve_jump_target(headers, 12, "prev", 0))
    end)

    it("stops at the last header when the count overshoots", function()
      -- Refusing to move would be worse: 5]u near the end should still reach the end.
      assert.equals(12, Controller._resolve_jump_target(headers, 1, "next", 99))
      assert.equals(4, Controller._resolve_jump_target(headers, 12, "prev", 99))
    end)

    it("returns nil past the last and before the first header", function()
      assert.is_nil(Controller._resolve_jump_target(headers, 12, "next"))
      assert.is_nil(Controller._resolve_jump_target(headers, 4, "prev"))
      assert.is_nil(Controller._resolve_jump_target({}, 1, "next"))
    end)
  end)
end)
