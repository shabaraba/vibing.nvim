--- Codex's tool names, translated to the canonical vocabulary the rest of vibing.nvim speaks.
---
--- Lives beside the adapter rather than in the permission handler so that shared infrastructure
--- never has to know which backend it is talking to: `codex_cli.lua` hands this module to
--- `set_active_opts` as a generic `_tool_vocabulary`, and the handler just calls whatever it was
--- given. See #516.
--- @module vibing.infrastructure.adapter.modules.codex_tool_vocabulary

local tools_constants = require("vibing.core.constants.tools")

local M = {}

---Codexの制御ツールだけを既定で許可する。共有の許可判定はバックエンドを知らず、
---このpredicateを通常のALWAYS_ALLOWED_TOOLSと同じ位置で評価する。
---@param tool_name string 正規化後のツール名
---@return boolean
function M.is_always_allowed(tool_name)
  -- functions経由のMCP名も組み込みツールの名前空間パターンに巻き込まない。
  if tool_name:lower():find("mcp__", 1, true) then
    return false
  end
  -- functions*に含まれていても通常のツールへ変換できる操作は通常の許可設定に従う。
  if tools_constants.VALID_TOOLS_MAP[tool_name] or M.to_canonical(tool_name) then
    return false
  end
  local matchers = require("vibing.infrastructure.permissions.matchers")
  for _, pattern in ipairs(tools_constants.CODEX_ALWAYS_ALLOWED_TOOL_PATTERNS) do
    if matchers.matches_permission(tool_name, {}, pattern) then
      return true
    end
  end
  return false
end

--- Captured from real codex 0.153.4 PreToolUse payloads, which vibing.nvim could not see until the
--- hook was registered under the key codex actually reads (`codex_settings_generator`):
---
---   shell:       {"tool_name":"Bash","tool_input":{"command":"echo hi"}}
---   file edit:   {"tool_name":"apply_patch","tool_input":{"command":"*** Begin Patch\n…"}}
---
--- So codex already speaks Claude's name for its shell tool and needs no entry for it. `shell` is
--- mapped anyway because it is what older codex sent and the mapping costs nothing.
---
--- Codex converges on Claude's vocabulary only for the tools that carry risk: `hook_names.rs` in
--- codex 0.154.0 serializes shell-likes (including `unified_exec`) as `Bash`, and gives
--- `apply_patch` the matcher aliases `Write`/`Edit` and `spawn_agent` the alias `Agent`. Its
--- remaining built-ins reach PreToolUse under their own names (`ToolName::plain`), so a `Read` or
--- `WebSearch` rule would miss them without the entries below. That asymmetry is also why the gap
--- was benign rather than a hole: nothing that writes or executes was ever unmapped.
--- @type table<string, string>
local NATIVE_TO_CANONICAL = {
  apply_patch = "Edit", -- Codex's file patch tool maps to Claude's Edit
  shell = "Bash",
  shell_command = "Bash",
  exec_command = "Bash",
  unified_exec = "Bash",
  -- Reads an image off disk to attach it. `Read` is in ALWAYS_ALLOWED_TOOLS, so this also stops
  -- codex prompting for every image the way an unmapped name does.
  view_image = "Read",
  read_file = "Read",
  web_search = "WebSearch",
  webrun = "WebSearch",
  ["web.run"] = "WebSearch",
  web__run = "WebSearch",
}

-- MCP server labels are normalized before Codex exposes them as tool names. In particular, the
-- bundled `vibing-nvim` server reaches PreToolUse as `mcp__vibing_nvim__...`. The shared
-- permission layer deliberately speaks the canonical (Claude-compatible) spelling, so restore
-- only this exact server prefix here. Keeping the match anchored avoids granting the special
-- bundled-server bypass to a lookalike such as `mcp__my_vibing_nvim__...`.
--
-- Derived from `tools_constants.VIBING_NVIM_MCP_TOOL_PATTERNS`, the single definition of the
-- bundled server's tool-name prefix, instead of a second hardcoded literal: `tools_spec.lua`
-- reads `claude-plugin/.claude-plugin/plugin.json` and fails if that constant drifts from the
-- manifest, and this ties the codex-only copy to the same guard rather than leaving one more
-- string that a manifest rename would silently strand.
local CANONICAL_VIBING_MCP_PREFIX = (tools_constants.VIBING_NVIM_MCP_TOOL_PATTERNS[1]):gsub("%*$", "")
local CODEX_VIBING_MCP_PREFIX = (CANONICAL_VIBING_MCP_PREFIX:gsub("%-", "_"))

--- @param native_tool_name string
--- @return string|nil canonical name, or nil when there is no mapping
function M.to_canonical(native_tool_name)
  if native_tool_name:sub(1, #CODEX_VIBING_MCP_PREFIX) == CODEX_VIBING_MCP_PREFIX then
    return CANONICAL_VIBING_MCP_PREFIX .. native_tool_name:sub(#CODEX_VIBING_MCP_PREFIX + 1)
  end
  -- 同じ組み込みツールでもfunctions.exec_command / functionsexec_commandで届く。
  -- 名前空間を外してから変換し、Bash/Editのdenyを名前の違いで迂回させない。
  local plain_name = native_tool_name:match("^functions%.(.+)$")
    or native_tool_name:match("^functions__(.+)$")
    or native_tool_name:match("^functions(.+)$")
  if plain_name and NATIVE_TO_CANONICAL[plain_name] then
    return NATIVE_TO_CANONICAL[plain_name]
  end
  if plain_name and tools_constants.VALID_TOOLS_MAP[plain_name] then
    return plain_name
  end
  return NATIVE_TO_CANONICAL[native_tool_name]
end

--- Extract every file touched by an apply_patch envelope, including both sides of a move.
--- Hunk lines carry a context/add/delete prefix, so anchored headers do not match file contents.
local function patch_paths(command)
  if type(command) ~= "string" then
    return nil
  end
  local lines = vim.split(vim.trim(command):gsub("\r\n", "\n"), "\n", { plain = true })
  if lines[1] ~= "*** Begin Patch" or lines[#lines] ~= "*** End Patch" then
    return nil
  end
  local paths, seen = {}, {}
  for _, line in ipairs(lines) do
    local path = line:match("^%*%*%* Add File: (.+)$")
      or line:match("^%*%*%* Update File: (.+)$")
      or line:match("^%*%*%* Delete File: (.+)$")
      or line:match("^%*%*%* Move to: (.+)$")
    if path and not seen[path] then
      seen[path] = true
      table.insert(paths, path)
    end
  end
  return paths
end

--- Keep the multi-file diff targets separate from the single-path permission contract.
--- Never manufacture file_path from the first patch header: that would misrepresent a multi-file
--- edit to granular permission rules. Those rules still need their own set-of-paths support.
---@param tool_input table
---@param tool_name? string canonical tool name
---@return table normalized copy (the original is never mutated)
function M.normalize_input(tool_input, tool_name)
  if type(tool_input) ~= "table" then
    return tool_input
  end
  local normalized = vim.tbl_extend("force", {}, tool_input)
  if not normalized.file_path and normalized.path then
    normalized.file_path = normalized.path
  end
  if tool_name == "Edit" then
    normalized._diff_paths = patch_paths(tool_input.command)
  end
  return normalized
end

return M
