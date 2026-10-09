--- The exceptions to `backends.codex.auto_approve`, as ordinary permission patterns.
---
--- One question only: **must this request be drawn for a human even though `auto_approve` is on**.
--- The patterns are the same grammar `permissions.ask` uses and are evaluated by the same
--- `matchers.matches_permission`, so `Bash(git push:*)` means here what it means there. A second
--- implementation of "does this rule match this call" is the drift this module exists to avoid.
---
--- It can only ever send a request **to** a human; there is no entry that approves one. So a rule
--- that fails to match costs what `auto_approve` already cost, and the failure direction of every
--- bug in here is one extra prompt.
--- @module vibing.infrastructure.adapter.modules.codex_auto_approve_rules

local Matchers = require("vibing.infrastructure.permissions.matchers")
local Request = require("vibing.infrastructure.adapter.modules.codex_native_request")

local M = {}

--- The tool names a codex file change is tested under.
---
--- The approval request does not say which of them codex would have called it, so a path is tested
--- under both and a match under either one asks. Guessing a single name would make
--- `Write(/etc/**)` silently never fire against a change codex happened to label an edit.
local FILE_CHANGE_TOOLS = { "Edit", "Write" }

--- Warn about a rule `matchers.lua` cannot make fire.
---
--- `Bash(x:*)` compares **only the command's first word** against `x`, so a multi-word prefix such
--- as `Bash(git push:*)` matches nothing, ever, and does it in silence -- the same shape as the
--- Permission Builder invariant about arguments `matchers.lua` cannot parse. The fix is not applied
--- here: `matches_bash_pattern` is shared with `permissions.allow` / `ask` / `deny`, where widening
--- it would start *allowing* calls that an existing rule does not allow today. So this says so
--- instead, once per distinct rule, and names the shape that does work.
--- @param rule string
local function warn_if_unfireable(rule)
  local parsed = Matchers.parse_tool_pattern(rule)
  if parsed.type ~= "bash_wildcard" then
    return
  end
  local base = tostring(parsed.rule_content or ""):match("^([^:]+)") or ""
  if not base:find("%s") then
    return
  end
  require("vibing.core.utils.notify").warn_once(
    "codex_auto_approve_ask_unfireable:" .. rule,
    string.format(
      "backends.codex.auto_approve_ask: '%s' can never match -- `Tool(x:*)` compares only the "
        .. "command's first word. Write 'Bash(%s)' instead, which matches that prefix.",
      rule,
      base
    )
  )
end

--- @param rules string[]
--- @param tool_name string
--- @param input table
--- @return boolean
local function any_rule_matches(rules, tool_name, input)
  for _, rule in ipairs(rules) do
    if Matchers.matches_permission(tool_name, input, rule) then
      return true
    end
  end
  return false
end

--- **Every** path in the change set is tested, not the first one.
---
--- A codex patch carries several paths in one envelope, and matching only the first is the evasion
--- `architecture.md` already records against filling `file_path` from it: a rule would be dodged by
--- patch ordering alone. Asking when any path matches has no such ordering.
--- @param rules string[]
--- @param changes table[]|nil
--- @return boolean
local function changes_match(rules, changes)
  for _, change in ipairs(type(changes) == "table" and changes or {}) do
    local path = type(change) == "table" and type(change.path) == "string" and change.path or nil
    if path then
      for _, tool_name in ipairs(FILE_CHANGE_TOOLS) do
        if any_rule_matches(rules, tool_name, { file_path = path }) then
          return true
        end
      end
    end
  end
  return false
end

--- Whether this request goes to a human despite `auto_approve`.
---
--- A request whose content cannot be read -- no command on an exec approval, no paths on a file
--- change -- matches nothing and is auto-answered, which is the same thing `auto_approve` alone
--- does with it. Treating "unreadable" as "ask" would turn the empty rule list into a feature that
--- prompts for everything.
--- @param method string
--- @param params table|nil
--- @param changes table[]|nil the `item/started` changes for this item, when known
--- @param rules string[]|nil `backends.codex.auto_approve_ask`
--- @return boolean
function M.must_ask(method, params, changes, rules)
  rules = type(rules) == "table" and rules or {}
  if #rules == 0 then
    return false
  end
  for _, rule in ipairs(rules) do
    warn_if_unfireable(rule)
  end

  params = type(params) == "table" and params or {}
  if Request.METHODS[method] == "file_change" then
    -- The legacy method carries its own changes; the modern one is handed the item's.
    local list = changes or (type(params.fileChanges) == "table" and params.fileChanges) or nil
    return changes_match(rules, list)
  end

  if type(params.command) ~= "string" or params.command == "" then
    return false
  end
  return any_rule_matches(rules, "Bash", { command = params.command })
end

return M
