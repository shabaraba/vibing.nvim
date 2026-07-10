local can_use_tool = require("vibing.infrastructure.permissions.can_use_tool")

--- Build a minimal PermissionConfig for tests
---@param overrides table
---@return PermissionConfig
local function make_config(overrides)
  return vim.tbl_extend("force", {
    allowed_tools = {},
    denied_tools = {},
    asked_tools = {},
    session_allowed_tools = {},
    session_denied_tools = {},
    permission_rules = {},
    permission_mode = "default",
    mcp_enabled = false,
  }, overrides or {})
end

describe("can_use_tool", function()
  describe("ALWAYS_ALLOWED_TOOLS (UT-PERM-010)", function()
    local always_allowed = { "Read", "Skill", "StructuredOutput" }

    for _, tool in ipairs(always_allowed) do
      it(string.format("should allow %s even when permissions_allow is empty", tool), function()
        local result = can_use_tool.can_use_tool(tool, {}, make_config({
          allowed_tools = {},
        }))
        assert.equals("allow", result.behavior)
      end)

      it(string.format("should allow %s even when permissions_allow does not include it", tool), function()
        local result = can_use_tool.can_use_tool(tool, {}, make_config({
          allowed_tools = { "Edit", "Write" },
        }))
        assert.equals("allow", result.behavior)
      end)

      it(string.format("should deny %s when explicitly in deny list", tool), function()
        local result = can_use_tool.can_use_tool(tool, {}, make_config({
          denied_tools = { tool },
        }))
        assert.equals("deny", result.behavior)
      end)

      it(string.format("should ask for %s when in ask list", tool), function()
        local result = can_use_tool.can_use_tool(tool, {}, make_config({
          asked_tools = { tool },
        }))
        assert.equals("ask", result.behavior)
      end)

      it(string.format("should deny %s when in both deny and ask lists (deny wins)", tool), function()
        local result = can_use_tool.can_use_tool(tool, {}, make_config({
          denied_tools = { tool },
          asked_tools = { tool },
        }))
        assert.equals("deny", result.behavior)
      end)
    end
  end)

  describe("non-always-allowed tools are still gated by allow list (UT-PERM-011)", function()
    it("should ask for Bash when not in allow list and mode is default", function()
      local result = can_use_tool.can_use_tool("Bash", {}, make_config({
        allowed_tools = { "Read", "Edit" },
        permission_mode = "default",
      }))
      assert.equals("ask", result.behavior)
    end)

    it("should allow Edit when in allow list", function()
      local result = can_use_tool.can_use_tool("Edit", {}, make_config({
        allowed_tools = { "Edit" },
      }))
      assert.equals("allow", result.behavior)
    end)
  end)

  describe("vibing-nvim MCP tools (regardless of registration namespace)", function()
    local tool_names = {
      -- Registered as a plain user-level MCP server
      "mcp__vibing-nvim__nvim_get_buffer",
      -- Registered as a Claude Code plugin (marketplace + plugin name both "vibing-nvim")
      "mcp__plugin_vibing-nvim_vibing-nvim__nvim_get_buffer",
    }

    for _, tool_name in ipairs(tool_names) do
      it(string.format("should allow %s without permissions_allow when mcp_enabled", tool_name), function()
        local result = can_use_tool.can_use_tool(tool_name, {}, make_config({
          allowed_tools = {},
          permission_mode = "default",
          mcp_enabled = true,
        }))
        assert.equals("allow", result.behavior)
      end)

      it(string.format("should deny %s when mcp_enabled is false", tool_name), function()
        local result = can_use_tool.can_use_tool(tool_name, {}, make_config({
          mcp_enabled = false,
        }))
        assert.equals("deny", result.behavior)
      end)

      it(string.format("should still deny %s when explicitly in deny list", tool_name), function()
        local result = can_use_tool.can_use_tool(tool_name, {}, make_config({
          denied_tools = { tool_name },
          mcp_enabled = true,
        }))
        assert.equals("deny", result.behavior)
      end)
    end

    it("does not match unrelated MCP tools", function()
      local result = can_use_tool.can_use_tool("mcp__chrome-devtools__navigate_page", {}, make_config({
        allowed_tools = { "Read", "Edit" },
        permission_mode = "default",
        mcp_enabled = true,
      }))
      assert.equals("ask", result.behavior)
    end)
  end)

  describe("is_vibing_nvim_mcp_tool", function()
    it("matches a specific tool regardless of registration namespace", function()
      assert.is_true(
        can_use_tool.is_vibing_nvim_mcp_tool(
          "mcp__plugin_vibing-nvim_vibing-nvim__nvim_ask_user_question",
          "nvim_ask_user_question"
        )
      )
      assert.is_true(
        can_use_tool.is_vibing_nvim_mcp_tool("mcp__vibing-nvim__nvim_ask_user_question", "nvim_ask_user_question")
      )
    end)

    it("does not match a different vibing-nvim tool", function()
      assert.is_false(
        can_use_tool.is_vibing_nvim_mcp_tool(
          "mcp__plugin_vibing-nvim_vibing-nvim__nvim_get_buffer",
          "nvim_ask_user_question"
        )
      )
    end)

    it("does not match native AskUserQuestion", function()
      assert.is_false(can_use_tool.is_vibing_nvim_mcp_tool("AskUserQuestion", "nvim_ask_user_question"))
    end)
  end)
end)
