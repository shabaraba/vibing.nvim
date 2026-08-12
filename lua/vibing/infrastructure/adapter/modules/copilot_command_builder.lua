--- Copilot CLI command builder for `copilot -p --output-format json` execution
--- Builds the command array for the GitHub Copilot CLI with JSONL output
--- @module vibing.infrastructure.adapter.modules.copilot_command_builder

local Modes = require("vibing.core.constants.modes")

local M = {}

--- Resolve model name from opts or config
--- Claude short names (sonnet/opus/haiku/fable) are not valid copilot model ids,
--- so they are dropped and copilot's own default is used instead.
--- @param opts Vibing.AdapterOpts
--- @param config Vibing.Config
--- @return string|nil
local function resolve_model(opts, config)
  local model = opts.model or (config.agent and config.agent.default_model)
  if model and Modes.is_valid_model(model) then
    return nil
  end
  return model
end

--- Resolve language setting
--- @param opts Vibing.AdapterOpts
--- @param config Vibing.Config
--- @return string|nil
local function resolve_language(opts, config)
  local language = opts.language
  if not language and config.language then
    if type(config.language) == "table" then
      language = config.language.default or config.language.chat
    else
      language = config.language
    end
  end
  return type(language) == "string" and language or nil
end

--- Build context prefix for the prompt
--- @param opts Vibing.AdapterOpts
--- @return string context_prefix Empty string if no context
local function build_context_prefix(opts)
  local parts = {}
  for _, ctx in ipairs(opts.context or {}) do
    if ctx:match("^@file:") then
      table.insert(parts, string.format("Context file: %s", ctx:sub(7)))
    end
  end
  if #parts == 0 then
    return ""
  end
  return table.concat(parts, "\n") .. "\n\n"
end

--- Map a vibing permission entry to a copilot permission pattern
--- The bare kind name matches every invocation of that kind; empty parens ("shell()")
--- are rejected by the CLI as an invalid rule format.
--- @param entry string
--- @return string|nil
function M.to_deny_pattern(entry)
  local bash_pattern = entry:match("^Bash%((.+)%)$")
  if bash_pattern then
    return string.format("shell(%s)", bash_pattern)
  end
  if entry == "Bash" then
    return "shell"
  end
  if entry == "Write" or entry == "Edit" then
    return "write"
  end
  if entry == "WebFetch" or entry == "WebSearch" then
    return "url"
  end
  return nil
end

--- Entries already reported as unsupported, so a repeated request does not re-warn.
--- @type table<string, boolean>
local warned_unmapped = {}

--- Reset the unsupported-deny-entry warning state. Test seam only.
function M._reset_unmapped_warnings()
  warned_unmapped = {}
end

--- Convert a deny list into deduplicated copilot patterns, preserving input order.
--- Entries copilot has no permission pattern for are dropped, and warned about once each —
--- silently ignoring them would leave the user believing a tool is blocked when it is not.
--- @param deny string[]|nil
--- @return string[]
function M.build_deny_patterns(deny)
  local patterns, seen = {}, {}
  local unmapped = {}

  for _, entry in ipairs(deny or {}) do
    local pattern = M.to_deny_pattern(entry)
    if pattern then
      if not seen[pattern] then
        seen[pattern] = true
        table.insert(patterns, pattern)
      end
    elseif not warned_unmapped[entry] then
      warned_unmapped[entry] = true
      table.insert(unmapped, entry)
    end
  end

  if #unmapped > 0 then
    vim.notify(
      string.format(
        "[vibing] copilot has no deny pattern for %s; %s will not be blocked",
        table.concat(unmapped, ", "),
        #unmapped == 1 and "it" or "they"
      ),
      vim.log.levels.WARN
    )
  end

  return patterns
end

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

  for _, pattern in ipairs(M.build_deny_patterns(opts.permissions_deny)) do
    table.insert(cmd, "--deny-tool")
    table.insert(cmd, pattern)
  end
end

--- Build the `copilot -p --output-format json` command array
--- @param prompt string User prompt
--- @param opts Vibing.AdapterOpts Adapter options
--- @param session_id string|nil Session ID for resumption
--- @param config Vibing.Config Plugin config
--- @return string[] Command array for vim.system()
function M.build(prompt, opts, session_id, config)
  local copilot_path = vim.fn.exepath("copilot")
  if copilot_path == "" then
    error("Copilot CLI not found in PATH. Please install GitHub Copilot CLI.")
  end

  local cmd = { copilot_path, "--output-format", "json", "--stream", "on", "--no-color" }

  if session_id then
    table.insert(cmd, "--resume=" .. session_id)
  end

  local model = resolve_model(opts, config)
  if model then
    table.insert(cmd, "--model")
    table.insert(cmd, model)
  end

  append_permission_flags(cmd, opts)

  local full_prompt = prompt
  if not session_id then
    full_prompt = build_context_prefix(opts) .. prompt
  end

  local language = resolve_language(opts, config)
  if language and language ~= "en" then
    local language_utils = require("vibing.core.utils.language")
    local lang_name = language_utils.language_names[language]
    if lang_name then
      full_prompt = string.format("Always respond in %s (%s).\n\n%s", lang_name, language, full_prompt)
    end
  end

  table.insert(cmd, "-p")
  table.insert(cmd, full_prompt)

  return cmd
end

return M
