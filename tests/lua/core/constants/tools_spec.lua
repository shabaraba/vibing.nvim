local Tools = require("vibing.core.constants.tools")

---Read the bundled plugin's own manifest — the one `--plugin-dir` loads.
---@return table
local function plugin_manifest()
  local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h:h:h:h")
  local path = root .. "/claude-plugin/.claude-plugin/plugin.json"
  assert.equals(1, vim.fn.filereadable(path), "plugin.json not found at " .. path)
  return vim.json.decode(table.concat(vim.fn.readfile(path), "\n"))
end

describe("tools constants", function()
  describe("VIBING_NVIM_MCP_TOOL_PATTERNS", function()
    -- `--allowedTools` takes literal prefixes, so this list cannot be derived from the plugin
    -- manifest at runtime — it has to be maintained by hand, and this is what catches a rename.
    --
    -- It reads plugin.json, not marketplace.json, because the prefix is built from the *plugin*
    -- name and the MCP server name; the marketplace name never appears in it. This spec used to
    -- assert the marketplace form (`mcp__plugin_vibing_vibing-nvim__*`) and so guarded a prefix
    -- the CLI has never once emitted. Since #618 the plugin is not installed through a
    -- marketplace at all — it is loaded per session with `--plugin-dir` — and the prefix is
    -- unchanged, because how the plugin is loaded was never what decided it.
    it("covers the prefix built from the bundled plugin's name and MCP server name", function()
      local manifest = plugin_manifest()
      assert.is_string(manifest.name)
      assert.is_table(manifest.mcpServers)

      for server_name in pairs(manifest.mcpServers) do
        local expected = ("mcp__plugin_%s_%s__*"):format(manifest.name, server_name)
        assert.is_true(
          vim.tbl_contains(Tools.VIBING_NVIM_MCP_TOOL_PATTERNS, expected),
          ("%s is missing; add it when renaming the plugin or its MCP server"):format(expected)
        )
      end
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
