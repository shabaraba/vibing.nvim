local Tools = require("vibing.core.constants.tools")

---Read the marketplace name the plugin is actually published under.
---@return string
local function marketplace_name()
  local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h:h:h:h")
  local path = root .. "/.claude-plugin/marketplace.json"
  assert.equals(1, vim.fn.filereadable(path), "marketplace.json not found at " .. path)
  local manifest = vim.json.decode(table.concat(vim.fn.readfile(path), "\n"))
  assert.is_string(manifest.name)
  return manifest.name
end

describe("tools constants", function()
  describe("VIBING_NVIM_MCP_TOOL_PATTERNS", function()
    -- `--allowedTools` takes literal prefixes, so this list cannot be derived from the
    -- marketplace name at runtime — it has to be maintained by hand. It fell out of date
    -- exactly once already: marketplace.json was renamed to "vibing" and this list kept
    -- saying "vibing-nvim", so the pre-approval silently matched nothing. Nothing caught it,
    -- because the PreToolUse hook's suffix match kept ordinary chats working.
    it("covers the marketplace name the plugin is currently published under", function()
      local expected = ("mcp__plugin_%s_vibing-nvim__*"):format(marketplace_name())
      assert.is_true(
        vim.tbl_contains(Tools.VIBING_NVIM_MCP_TOOL_PATTERNS, expected),
        ("%s is missing; add it when renaming the marketplace"):format(expected)
      )
    end)

    it("covers the plain user-level MCP server registration", function()
      assert.is_true(vim.tbl_contains(Tools.VIBING_NVIM_MCP_TOOL_PATTERNS, "mcp__vibing-nvim__*"))
    end)

    -- Every entry has to survive can_use_tool's suffix match too, or the two halves of the
    -- grant disagree: --allowedTools would pre-approve a name the hook then refuses to allow.
    it("only lists prefixes the PreToolUse hook also recognises", function()
      local CanUseTool = require("vibing.infrastructure.permissions.can_use_tool")
      for _, pattern in ipairs(Tools.VIBING_NVIM_MCP_TOOL_PATTERNS) do
        local sample = pattern:gsub("%*$", "") .. "nvim_get_buffer"
        assert.is_true(CanUseTool.is_vibing_nvim_mcp_tool(sample), sample .. " is not recognised")
      end
    end)
  end)
end)
