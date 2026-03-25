--- Permission system module entry point
--- @module vibing.infrastructure.permissions

local matchers = require("vibing.infrastructure.permissions.matchers")
local rule_checker = require("vibing.infrastructure.permissions.rule_checker")
local can_use_tool = require("vibing.infrastructure.permissions.can_use_tool")

return {
  matchers = matchers,
  rule_checker = rule_checker,
  can_use_tool = can_use_tool.can_use_tool,
  add_session_allow = can_use_tool.add_session_allow,
  add_session_deny = can_use_tool.add_session_deny,
}
