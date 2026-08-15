--- Copilot CLI command builder for `copilot -p --output-format json` execution
--- Builds the command array for the GitHub Copilot CLI with JSONL output
--- @module vibing.infrastructure.adapter.modules.copilot_command_builder

local NonClaudeModel = require("vibing.infrastructure.adapter.modules.non_claude_model")
local CommonBuilder = require("vibing.infrastructure.adapter.modules.command_builder_common")

local binary_path = CommonBuilder.binary_resolver(
  "copilot",
  "Copilot CLI not found in PATH. Please install GitHub Copilot CLI."
)

local M = {}

local ToolVocabulary = require("vibing.infrastructure.adapter.modules.copilot_tool_vocabulary")

--- A tool name copilot does not have, handed to `--available-tools` to leave the model with an
--- empty toolset.
---
--- `--available-tools` is documented as the filter that "disables all other tools" and decides
--- "which tools the model can see" (`copilot help permissions`), so a list matching nothing
--- resolves to nothing. Verified against copilot 1.0.78 by counting the tool schemas in
--- `--log-level debug` output: an ordinary run offers 62 tools, `--available-tools=view` offers
--- exactly 1, and this sentinel offers 0 — and the turn still completes normally
--- (`toolRequests: []`, exit 0), so an empty toolset is not an error to copilot.
---
--- The value has to be a name rather than an empty string. `--available-tools=` parses as an
--- empty list, which copilot ignores outright: it left all 62 tools in place, the same silent
--- no-op grok has for `--tools ""`.
local NO_TOOLS_SENTINEL = "__vibing_no_tools__"

--- Append permission flags. copilot's non-interactive mode requires --allow-all-tools,
--- so denies are expressed with --deny-tool rather than an allow list.
--- @param cmd string[]
--- @param opts Vibing.AdapterOpts
local function append_permission_flags(cmd, opts)
  local permission_mode = opts.permission_mode or "default"

  if permission_mode == "bypassPermissions" then
    table.insert(cmd, "--allow-all")
    return
  end

  if permission_mode == "plan" then
    table.insert(cmd, "--plan")
  end
  table.insert(cmd, "--allow-all-tools")

  for _, pattern in ipairs(ToolVocabulary.build_deny_patterns(opts.permissions_deny)) do
    table.insert(cmd, "--deny-tool")
    table.insert(cmd, pattern)
  end
end

--- Append the flags a lightweight utility call (title generation, /summarize, daily summary)
--- runs under, in place of the permission flags.
---
--- This is copilot's half of what `lightweight` promises in `core/types.lua`. Unlike codex,
--- copilot can genuinely take the tools away, so there is no sandbox to fence anything into:
--- `--available-tools` filters the user's MCP tools too (the 62-tool baseline above includes
--- them, and the sentinel leaves 0), which covers claude's `--strict-mcp-config` in one flag.
--- The MCP servers themselves are still spawned, but expose nothing to the model.
---
--- `--allow-all-tools` stays because copilot requires it in non-interactive mode at all, not
--- because anything is left to allow. `permission_mode` is deliberately ignored,
--- `bypassPermissions` included: the user put the *chat* in that mode, and a title generated
--- behind their back is not the call they made.
--- @param cmd string[]
local function append_lightweight_flags(cmd)
  table.insert(cmd, "--allow-all-tools")
  table.insert(cmd, "--available-tools=" .. NO_TOOLS_SENTINEL)
  -- claude's `--setting-sources ""` and codex's `project_doc_max_bytes=0`. Verified on 1.0.78:
  -- an AGENTS.md sentinel string reaches the prompt twice without this flag and not at all
  -- with it.
  table.insert(cmd, "--no-custom-instructions")
end

--- Forget the resolved binary path. Test seam only: the cache is process-wide, so a spec
--- exercising the "CLI missing" path has to clear what an earlier spec resolved.
function M._reset_path_cache()
  binary_path.reset()
end

--- Build the `copilot -p --output-format json` command array
--- @param prompt string User prompt
--- @param opts Vibing.AdapterOpts Adapter options
--- @param session_id string|nil Session ID for resumption
--- @param config Vibing.Config Plugin config
--- @return string[] Command array for vim.system()
function M.build(prompt, opts, session_id, config)
  local cmd = { binary_path.resolve(), "--output-format", "json", "--stream", "on", "--no-color" }

  if session_id then
    table.insert(cmd, "--resume=" .. session_id)
  end

  local model = NonClaudeModel.resolve(opts, config)
  if model then
    table.insert(cmd, "--model")
    table.insert(cmd, model)
  end

  if opts.lightweight then
    append_lightweight_flags(cmd)
  else
    append_permission_flags(cmd, opts)
  end

  local full_prompt = prompt
  if not session_id then
    full_prompt = CommonBuilder.context_prefix(opts) .. prompt
  end

  local language_instruction = CommonBuilder.language_instruction(opts, config)
  if language_instruction then
    full_prompt = language_instruction .. "\n\n" .. full_prompt
  end

  table.insert(cmd, "-p")
  table.insert(cmd, full_prompt)

  return cmd
end

return M
