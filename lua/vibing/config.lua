--- Public configuration. Objects merge recursively; lists replace, including empty lists.
local Agents = require("vibing.core.constants.agents")
local Tools = require("vibing.core.constants.tools")
local Usage = require("vibing.core.utils.token_usage")
local Notify = require("vibing.core.utils.notify")
local M = {}

---@class Vibing.Profile
---@field name string
---@field description? string
---@field agent? string
---@field model? string
---@field effort? string
---@field tools? string[]
---@field setting_sources? string[]
---@field context_files? string[]
---@class Vibing.AiSelection
---@field agent? string
---@field model? string
---@field effort? string
---@class Vibing.AgentOptions
---@field path? string Executable path; absent means PATH lookup.
---@field process? "oneshot"|"duplex"
---@field env? table<string, string|number>
---@field settings? table
---@field mcp? table
---@field extensions? table
---@class Vibing.WindowConfig
---@field position "current"|"right"|"left"|"top"|"bottom"|"back"|"float"
---@field width number
---@field height? number
---@field border string
---@class Vibing.ChatConfig
---@field language? string|{default?: string, chat?: string}
---@field storage {location: "project"|"user"|"custom", path: string}
---@field context {auto_include: boolean, warn_tokens: number, cache_ttl_sec: number, compaction: {enabled: boolean, threshold_tokens: number, focus?: string}}
---@field daily_summary Vibing.DailySummaryConfig
---@class Vibing.DailySummaryConfig
---@field save_dir? string
---@field search_dirs string[]
---@field file_finder_strategy "auto"|"fd"|"find"|"locate"|"ripgrep"
---@class Vibing.DiffConfig
---@field layout "split"|"unified"
---@field fill_char string
---@field highlights boolean
---@class Vibing.UiConfig
---@field window Vibing.WindowConfig
---@field wrap "on"|"off"|"nvim"
---@field gradient {enabled: boolean, colors: string[], interval_ms: number, waiting_color: string}
---@field tools {results: "compact"|"full"|"none", markers: table<string, string>}
---@field subagents {show_output: boolean, show_prefix: boolean}
---@field usage {enabled: boolean}
---@field fold {enabled: boolean}
---@field diff Vibing.DiffConfig
---@class Vibing.PermissionRule
---@field tools string[]
---@field action "allow"|"deny"
---@field paths? string[]
---@field commands? string[]
---@field patterns? string[]
---@field domains? string[]
---@field message? string
---@class Vibing.PermissionsConfig
---@field mode string
---@field allow string[]
---@field deny string[]
---@field ask string[]
---@field rules Vibing.PermissionRule[]
---@field default_deny_rules boolean
---@field approval_wait_sec number
---@field delegated_approval boolean|"scoped"
---@class Vibing.McpConfig
---@field enabled boolean
---@field port integer
---@class Vibing.DapConfig
---@field enabled boolean
---@field auto_analyze_on_error boolean
---@field auto_analyze_on_breakpoint boolean
---@class Vibing.Config
---@field ai {chat: Vibing.AiSelection, helpers: Vibing.AiSelection, agents: table<string, Vibing.AgentOptions>, profiles: Vibing.Profile[]}
---@field chat Vibing.ChatConfig
---@field ui Vibing.UiConfig
---@field keymaps table<string, string>
---@field permissions Vibing.PermissionsConfig
---@field automation table Limit handling and orchestration.
---@field integrations table Neovim, plugins and DAP.

M.defaults = {
  ai = {
    chat = { agent = Agents.DEFAULT, effort = "default" },
    helpers = { effort = "low" },
    profiles = {},
    agents = {},
  },
  chat = {
    storage = { location = "project", path = vim.fn.stdpath("data") .. "/vibing/chats" },
    context = {
      auto_include = true,
      warn_tokens = Usage.DEFAULT_WARN_CONTEXT,
      cache_ttl_sec = Usage.DEFAULT_CACHE_TTL_SEC,
      compaction = { enabled = false, threshold_tokens = Usage.DEFAULT_AUTO_COMPACT_AT },
    },
    daily_summary = { search_dirs = {}, file_finder_strategy = "auto" },
  },
  ui = {
    window = { position = "current", width = 0.4, border = "rounded" },
    wrap = "on",
    gradient = { enabled = true, colors = { "#cc3300", "#fffe00" }, interval_ms = 100, waiting_color = "#3fa9f5" },
    tools = { results = "compact", markers = { Task = "▶", default = "⏺" } },
    fold = { enabled = true },
    subagents = { show_output = false, show_prefix = false },
    usage = { enabled = true },
    diff = { layout = "split", fill_char = "╱", highlights = true },
  },
  keymaps = {
    send = "<CR>",
    cancel = "<C-c>",
    add_context = "<C-a>",
    open_diff = "gd",
    open_file = "gf",
    open_url = "gx",
    cycle_enum_next = "]v",
    cycle_enum_prev = "[v",
  },
  permissions = {
    mode = "acceptEdits",
    allow = vim.deepcopy(Tools.DEFAULT_ALLOWED_TOOLS),
    deny = { "Bash" },
    ask = {},
    rules = {},
    default_deny_rules = true,
    approval_wait_sec = 900,
    delegated_approval = false,
  },
  automation = {
    limits = {
      continue_prompt = "Continue from where you left off.",
      fallback_delay_sec = 300,
      grace_sec = 10,
      resume = { enabled = false, max_retries = 1 },
      queue = { enabled = true, max_retries = 3 },
    },
    orchestration = {
      max_concurrent = 0,
      max_concurrent_subagents = 0,
      worker_defaults = {},
      notifications = { enabled = false, max_round_trips = 8, max_wakes = 50 },
    },
  },
  integrations = {
    nvim = { enabled = true, port = 9876 },
    plugins = { self = true, project_dir = ".vibing/plugins", extra = {} },
    dap = { enabled = false, auto_analyze_on_error = true, auto_analyze_on_breakpoint = false },
  },
}

for _, def in ipairs(Agents.list()) do
  local extensions = {}
  for name, field in pairs(Agents.config_fields(def.id)) do
    extensions[name] =
      vim.deepcopy(field.default_module and require(field.default_module)[field.default_field] or field.default)
  end
  local options = { process = "oneshot", env = {}, settings = {}, mcp = {}, extensions = extensions }
  local support = def.config_support or {}
  if support.settings_sources then
    options.settings.sources = { "user", "project", "local" }
  end
  if support.inherit_cli_servers then
    options.mcp.inherit_cli_servers = true
  end
  M.defaults.ai.agents[def.id] = options
end

local function enum(values)
  return { kind = "enum", values = values }
end
local function list(item)
  return { kind = "list", item = item or "string" }
end
local function map(item)
  return { kind = "map", item = item }
end
local function number(min, integer)
  return { kind = "number", min = min, integer = integer }
end
local nonempty = { kind = "nonempty" }
local environment = { kind = "env_value" }
local path_or_false = { kind = "path_or_false" }
local color = { kind = "color" }

local function inferred(value)
  if type(value) ~= "table" then
    return type(value)
  end
  if vim.islist(value) and next(value) then
    return list()
  end
  local out = {}
  for k, v in pairs(value) do
    out[k] = inferred(v)
  end
  return out
end
local schema = inferred(M.defaults)
schema.ai.chat.agent = enum(Agents.ORDER)
schema.ai.chat.model = nonempty
schema.ai.chat.effort = enum(require("vibing.core.constants.modes").EFFORT_VALUES)
schema.ai.helpers = vim.deepcopy(schema.ai.chat)
schema.ai.profiles = list({
  name = nonempty,
  description = "string",
  agent = enum(Agents.ORDER),
  model = nonempty,
  effort = enum(require("vibing.core.constants.modes").EFFORT_VALUES),
  tools = list(nonempty),
  setting_sources = list(enum({ "user", "project", "local" })),
  context_files = list(nonempty),
})
schema.automation.orchestration.worker_defaults = vim.deepcopy(schema.ai.chat)
schema.automation.orchestration.worker_defaults.profile = nonempty
schema.chat.language = { kind = "language" }
schema.chat.storage.location = enum({ "project", "user", "custom" })
schema.chat.storage.path = nonempty
schema.chat.daily_summary.save_dir = nonempty
schema.chat.daily_summary.search_dirs = list(nonempty)
schema.chat.daily_summary.file_finder_strategy = enum({ "auto", "fd", "find", "locate", "ripgrep" })
schema.chat.context.compaction.focus = "string"
schema.ui.window.height = number(0)
schema.ui.window.width = number(0)
schema.ui.window.position = enum({ "right", "left", "top", "bottom", "back", "current", "float" })
schema.ui.wrap = enum({ "nvim", "on", "off" })
schema.ui.tools.results = enum({ "none", "compact", "full" })
schema.ui.tools.markers = map(nonempty)
schema.ui.diff.layout = enum({ "split", "unified" })
schema.permissions.mode = enum(require("vibing.core.constants.modes").PERMISSION_MODES)
schema.permissions.delegated_approval = { kind = "delegation" }
schema.permissions.allow = list(nonempty)
schema.permissions.deny = list(nonempty)
schema.permissions.ask = list(nonempty)
schema.permissions.rules = list({
  tools = list(nonempty),
  paths = list(nonempty),
  commands = list(nonempty),
  patterns = list(nonempty),
  domains = list(nonempty),
  action = enum({ "allow", "deny" }),
  message = "string",
})
schema.integrations.plugins.self = "boolean"
schema.integrations.plugins.project_dir = path_or_false
schema.integrations.plugins.extra = list(nonempty)
schema.integrations.nvim.port = number(1, true)
schema.ui.gradient.interval_ms = number(1)
schema.ui.gradient.colors = list(color)
schema.ui.gradient.waiting_color = color
schema.automation.limits.resume.max_retries = number(0, true)
schema.automation.limits.queue.max_retries = number(0, true)
schema.permissions.approval_wait_sec = number(0)
for _, key in ipairs({ "warn_tokens", "cache_ttl_sec" }) do
  schema.chat.context[key] = number(0)
end
schema.chat.context.compaction.threshold_tokens = number(0)
for _, def in ipairs(Agents.list()) do
  local common = schema.ai.agents[def.id]
  common.path = nonempty
  common.process = enum({ "oneshot", "duplex" })
  common.env = map(environment)
  common.settings = { sources = list(enum({ "user", "project", "local" })) }
  common.mcp = { inherit_cli_servers = "boolean" }
  for name, field in pairs(Agents.config_fields(def.id)) do
    local rule = field.kind
    if rule == "string_list" then
      rule = list(nonempty)
    elseif rule == "path_or_false" then
      rule = path_or_false
    elseif rule == "number" then
      rule = number(field.min)
    elseif field.values then
      rule = enum(field.values)
    end
    common.extensions[name] = rule
  end
end

local removed = {
  adapter = "ai.chat.agent",
  agent = "ai.chat / ai.helpers / ai.agents / automation / ui",
  backends = "ai.agents",
  diff = "ui.diff (diff.tool was removed)",
  mcp = "integrations.nvim",
  language = "chat.language",
  daily_summary = "chat.daily_summary",
  dap = "integrations.dap",
  ["chat.window"] = "ui.window",
  ["chat.auto_context"] = "chat.context.auto_include",
  ["chat.save_dir"] = "chat.storage.path",
  ["chat.save_location_type"] = "chat.storage.location",
  ["chat.mode"] = "removed: mode never changed execution",
  ["ui.tool_markers"] = "ui.tools.markers",
  ["ui.tool_result_display"] = "ui.tools.results",
  ["ui.gradient.interval"] = "ui.gradient.interval_ms",
}

local function validate(value, rule, path, errors)
  local function fail(expected)
    errors[#errors + 1] = path .. ": expected " .. expected
  end
  if type(rule) == "string" then
    if type(value) ~= rule then
      fail(rule)
    end
    return
  end
  local kind = rule.kind
  if kind == "enum" then
    if not vim.tbl_contains(rule.values, value) then
      fail(table.concat(rule.values, " | "))
    end
  elseif kind == "nonempty" then
    if type(value) ~= "string" or value == "" then
      fail("a non-empty string")
    end
  elseif kind == "color" then
    if type(value) ~= "string" or not value:match("^#%x%x%x%x%x%x$") then
      fail("a hex color like #ff0000")
    end
  elseif kind == "path_or_false" then
    if value ~= false then
      validate(value, nonempty, path, errors)
    end
  elseif kind == "env_value" then
    if type(value) ~= "string" and type(value) ~= "number" then
      fail("a string or number")
    end
  elseif kind == "delegation" then
    if type(value) ~= "boolean" and value ~= "scoped" then
      fail('a boolean or "scoped"')
    end
  elseif kind == "number" then
    if
      type(value) ~= "number"
      or value ~= value
      or value == math.huge
      or value == -math.huge
      or (rule.min and value < rule.min)
      or (rule.integer and value % 1 ~= 0)
    then
      fail("a valid number" .. (rule.min and " >= " .. rule.min or ""))
    end
  elseif kind == "language" then
    if type(value) ~= "string" then
      validate(value, { default = nonempty, chat = nonempty }, path, errors)
    end
  elseif type(value) ~= "table" then
    fail("a table")
  elseif kind == "list" then
    if not vim.islist(value) then
      fail("a list")
    else
      for i, item in ipairs(value) do
        validate(item, rule.item, path .. "[" .. i .. "]", errors)
      end
    end
  elseif kind == "map" then
    for key, item in pairs(value) do
      if type(key) ~= "string" then
        fail("string keys")
      else
        validate(item, rule.item, path .. "." .. key, errors)
      end
    end
  else
    for key, item in pairs(value) do
      local label = path == "" and tostring(key) or path .. "." .. tostring(key)
      if not rule[key] then
        errors[#errors + 1] = label .. (removed[label] and ": moved to " .. removed[label] or ": unknown option")
      else
        validate(item, rule[key], label, errors)
      end
    end
  end
end

--- Merge according to the schema, so an empty list replaces its default.
local function merge(base, opts, rule)
  local out = vim.deepcopy(base)
  for key, value in pairs(opts) do
    local r = rule[key]
    if type(value) == "table" and type(r) == "table" and r.kind == "map" then
      out[key] = vim.tbl_extend("force", vim.deepcopy(base[key] or {}), vim.deepcopy(value))
    elseif type(value) == "table" and type(r) == "table" and not r.kind then
      out[key] = merge(type(out[key]) == "table" and out[key] or {}, value, r)
    else
      out[key] = vim.deepcopy(value)
    end
  end
  return out
end

---@param opts? Vibing.Config
function M.setup(opts)
  if opts == nil then
    opts = {}
  end
  local errors = {}
  validate(opts, schema, "", errors)
  if #errors > 0 then
    error("Invalid vibing configuration:\n" .. table.concat(errors, "\n"), 2)
  end
  for id, options in pairs(vim.tbl_get(opts, "ai", "agents") or {}) do
    local def = Agents.get(id)
    local support = def.config_support or {}
    if options.settings and options.settings.sources ~= nil and not support.settings_sources then
      errors[#errors + 1] = "ai.agents." .. id .. ".settings.sources: unsupported by this agent"
    end
    if options.mcp and options.mcp.inherit_cli_servers ~= nil and not support.inherit_cli_servers then
      errors[#errors + 1] = "ai.agents." .. id .. ".mcp.inherit_cli_servers: unsupported by this agent"
    end
    if options.process == "duplex" and require(def.descriptor_module).process ~= "duplex" then
      errors[#errors + 1] = "ai.agents." .. id .. ".process: duplex is unsupported by this agent"
    end
  end
  if #errors > 0 then
    error("Invalid vibing configuration:\n" .. table.concat(errors, "\n"), 2)
  end
  local options = merge(M.defaults, opts, schema)
  -- Keep the existing Skill floor and tool-name diagnostics.
  local p = options.permissions
  if
    not vim.tbl_contains(p.allow, "Skill")
    and not vim.tbl_contains(p.deny, "Skill")
    and not vim.tbl_contains(p.ask, "Skill")
  then
    p.allow[#p.allow + 1] = "Skill"
  end
  for _, name in ipairs({ "allow", "deny", "ask" }) do
    for _, tool in ipairs(p[name]) do
      if not Tools.VALID_TOOLS_MAP[tool] and not tool:match("^mcp__") and not tool:match("^Bash%([^:]+:%*%)$") then
        Notify.warn("Unknown tool '" .. tool .. "' in permissions." .. name)
      end
    end
  end
  if #options.ui.gradient.colors ~= 2 then
    error("ui.gradient.colors requires exactly two colors", 2)
  end
  if vim.fn.strchars(options.ui.diff.fill_char) > 1 then
    error('ui.diff.fill_char must be one character or ""', 2)
  end
  if options.integrations.nvim.port > 65535 then
    error("integrations.nvim.port must be <= 65535", 2)
  end
  for _, rule in ipairs(p.rules) do
    if not rule.tools or not rule.action then
      error("permissions.rules requires tools and action", 2)
    end
  end
  for _, profile in ipairs(options.ai.profiles) do
    if not profile.name or not profile.name:match("^[%w_%-]+$") then
      error("ai.profiles requires a name containing letters, digits, _ or -", 2)
    end
  end
  M.options = options
end

---@return Vibing.Config
function M.get()
  return M.options or M.defaults
end
return M
