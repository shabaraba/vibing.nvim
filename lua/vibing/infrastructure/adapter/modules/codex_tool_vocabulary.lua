--- Codex's tool names, translated to the canonical vocabulary the rest of vibing.nvim speaks.
---
--- Lives beside the adapter rather than in the permission handler so that shared infrastructure
--- never has to know which backend it is talking to: `codex_cli.lua` hands this module to
--- `set_active_opts` as a generic `_tool_vocabulary`, and the handler just calls whatever it was
--- given. See #516.
--- @module vibing.infrastructure.adapter.modules.codex_tool_vocabulary

local tools_constants = require("vibing.core.constants.tools")

local M = {}

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
  -- Reads an image off disk to attach it. `Read` is in ALWAYS_ALLOWED_TOOLS, so this also stops
  -- codex prompting for every image the way an unmapped name does.
  view_image = "Read",
  web_search = "WebSearch",
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
  return NATIVE_TO_CANONICAL[native_tool_name]
end

--- Where codex puts the path a tool is about, for the tools that name one at all. `view_image`
--- declares a single required `path` (`view_image_spec.rs`), which is the same shape copilot uses,
--- so a granular `Read(...)` paths rule can reach it. Without this, mapping `view_image` to `Read`
--- above would read as covered by such a rule while silently never matching.
--- @param tool_input table
--- @return table input with `file_path` filled in when codex named it `path`. The original is
---   never mutated: the same payload is also used to render the approval UI.
function M.normalize_input(tool_input)
  if type(tool_input) ~= "table" or tool_input.file_path or not tool_input.path then
    return tool_input
  end

  return vim.tbl_extend("force", tool_input, { file_path = tool_input.path })
end

--- **Still uncovered above: `apply_patch`.** Known gap, not an oversight.
---
--- Codex does not put the *edited* path in a sibling key the way grok (`target_file`) and copilot
--- (`path`) do -- there is no path in an apply_patch `tool_input` at all. It is inside the
--- `command` string, as an envelope that may name several files at once:
---
---   *** Begin Patch
---   *** Update File: a.lua
---   *** Add File: b.lua
---   *** End Patch
---
--- Two consequences, both pre-existing and neither introduced by registering the hook (before that
--- fix no codex tool call reached this module at all):
---
---   - granular `paths` rules never match a codex edit, because `matchers.lua` reads a single
---     `input.file_path`;
---   - `request_diff.capture` backs nothing up, because it reads `tool_input.file_path`. Harmless
---     today: the git-snapshot path is the primary one and needs no path, only the baseline.
---
--- The reason this is not a two-line fix is the multi-file case. Filling `file_path` with the
--- *first* path parsed would read as working while letting a deny rule be evaded by patch
--- ordering, which is worse than not matching at all. Doing it properly means teaching the paths
--- matcher about a set of paths, and that is a change to shared permission code rather than to
--- this backend's seam.

return M
