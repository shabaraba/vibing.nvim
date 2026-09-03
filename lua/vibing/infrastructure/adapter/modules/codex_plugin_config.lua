--- Codex's substitute for `--plugin-dir`: the `-c` overrides that carry a plugin's MCP servers
--- and skills into one `codex exec` invocation.
---
--- Codex 0.153 has no per-run plugin flag. Its plugins arrive only through
--- `codex plugin add`, which copies the directory into `$CODEX_HOME` and enables it in
--- `config.toml` -- the global state that `--plugin-dir` was adopted to avoid (#618). A
--- repo-scoped `.agents/plugins/marketplace.json` is not discovered either, and
--- `-c plugins.<id>.enabled=true` does nothing for a plugin that was never installed. What
--- codex *does* take per invocation is a config override, so a plugin travels in two halves:
---
--- - **MCP servers** become `-c mcp_servers.<name>.{command,args,env}` overrides, with
---   `default_tools_approval_mode="approve"`. Headless `codex exec` auto-cancels an MCP call at
---   its own approval prompt (openai/codex#24135); that field is the answer, and it is per server,
---   so nothing else in the user's config is touched.
--- - **Skills** cannot be added as a skill root -- `skills.config` only toggles skills codex
---   already discovered, and the roots it scans (`$CODEX_HOME/skills`, `.agents/skills` up the
---   cwd) are the user's own. So they are listed in `developer_instructions`, in the shape codex
---   uses for its own skill list: name, description and the absolute `SKILL.md` to read.
---
--- What does not travel: `agents/` (codex has no equivalent) and anything a manifest names
--- with `.` or another non-bare character, because the `-c` dotted path is split on `.` and
--- takes each segment literally (`core/utils/toml.lua`).
---
--- Measurements behind all of this: `handbook/architecture/plugin-and-commands.md` → "Codex".
--- @module vibing.infrastructure.adapter.modules.codex_plugin_config

local PluginDirs = require("vibing.infrastructure.plugins.plugin_dirs")
local PluginContents = require("vibing.infrastructure.plugins.plugin_contents")
local Toml = require("vibing.core.utils.toml")
local Notify = require("vibing.core.utils.notify")

local M = {}

--- Per-cwd memo of the problems already reported, so a manifest that cannot be expressed warns
--- once rather than on every message. Cleared with `plugin_dirs`' own cache by
--- `:VibingReloadCommands`, which is what the user runs after fixing it.
--- @type table<string, boolean>
local warned = {}

--- @param cwd string|nil
--- @param problems string[]
local function warn_once(cwd, problems)
  local key = (cwd or "") .. "\n" .. table.concat(problems, "\n")
  if #problems == 0 or warned[key] then
    return
  end
  warned[key] = true
  Notify.warn(
    "not registered with codex, whose -c key path cannot carry the name: " .. table.concat(problems, ", "),
    "Plugins"
  )
end

--- Forget which problems were reported. Reached from `:VibingReloadCommands`.
function M.clear_cache()
  warned = {}
end

--- @param args string[]
--- @param key string
--- @param value string already rendered as TOML
local function override(args, key, value)
  table.insert(args, "-c")
  table.insert(args, key .. "=" .. value)
end

--- The `-c` overrides for one MCP server.
--- @param args string[]
--- @param server Vibing.PluginMcpServer
local function append_server(args, server)
  local prefix = "mcp_servers." .. server.name
  if server.command then
    override(args, prefix .. ".command", Toml.string(server.command))
    override(args, prefix .. ".args", Toml.string_array(server.args))
    if next(server.env) then
      override(args, prefix .. ".env", Toml.string_table(server.env))
    end
  else
    override(args, prefix .. ".url", Toml.string(server.url))
  end
  -- Values are auto / prompt / writes / approve (codex 0.153, `--strict-config`). Anything that
  -- can reach the prompt is cancelled in headless exec, so only `approve` lets the tools run at
  -- all. The permission decision stays with vibing.nvim's own hook, as it does for every tool.
  override(args, prefix .. ".default_tools_approval_mode", Toml.string("approve"))
end

--- The developer message that stands in for `--plugin-dir`'s skill loading and for the claude
--- system prompt's MCP paragraph.
---
--- Byte-stable across the turns of one chat: the entries come in `plugin_dirs` order, the skills
--- in sorted-glob order, and the port is fixed for the Neovim session. Codex's prompt cache
--- matches on a prefix, so any per-turn value here would invalidate it every turn (#469).
--- @param skills {plugin: string, skill: Vibing.PluginSkill}[]
--- @param self_server string|nil registered name of the bundled server, nil when it is not loaded
--- @param rpc_port number|nil
--- @return string|nil
local function developer_instructions(skills, self_server, rpc_port)
  local lines = {}

  if #skills > 0 then
    table.insert(
      lines,
      "vibing.nvim has loaded plugin skills for this session. A skill is a set of local "
        .. "instructions stored in a SKILL.md file. When a task matches a skill's description, "
        .. "read that file with your shell (it is readable inside the sandbox) and follow it. "
        .. "Available plugin skills:"
    )
    for _, item in ipairs(skills) do
      table.insert(lines, string.format("- %s:%s: %s", item.plugin, item.skill.name, item.skill.description))
      table.insert(lines, "  SKILL.md: " .. item.skill.path)
    end
  end

  if self_server then
    if #lines > 0 then
      table.insert(lines, "")
    end
    table.insert(
      lines,
      string.format(
        "The vibing-nvim MCP tools are registered as mcp__%s__<tool>; they read and edit the running "
          .. "Neovim instance the user is looking at. Do not call nvim_ask_user_question here -- the "
          .. "choice UI is not wired to this chat, so ask in plain text instead.",
        self_server
      )
    )
    if rpc_port then
      table.insert(
        lines,
        "Your rpc_port for this turn is "
          .. tostring(rpc_port)
          .. ". You MUST pass this exact value as the rpc_port argument on every vibing-nvim MCP tool "
          .. "call -- never omit it or guess, since other unrelated Neovim instances may be running and "
          .. "reachable on other ports."
      )
    end
  end

  if #lines == 0 then
    return nil
  end
  return table.concat(lines, "\n")
end

--- The `-c` overrides that load every applicable plugin into one `codex exec` run.
---
--- Servers are deduplicated by name, first plugin winning, which is the same precedence
--- `--plugin-dir` gives a duplicate plugin name: a project plugin cannot replace the bundled
--- `vibing-nvim` server by declaring one of its own.
--- @param cwd string|nil the chat's `working_dir`; nil means Neovim's own cwd
--- @param config Vibing.Config
--- @param rpc_port number|nil this Neovim's RPC port, told to the model when the bundled server loads
--- @return string[] argv fragment, empty when no plugin applies
function M.args(cwd, config, rpc_port)
  local args = {}
  local seen = {}
  local skills = {}
  local problems = {}
  local self_server = nil
  -- By path, not by the name "vibing-nvim": with `self = false` a project plugin could carry that
  -- name, and the developer message would then describe its server as the bundled one.
  local self_dir = PluginDirs.self_plugin_dir()

  for _, entry in ipairs(PluginDirs.resolve_entries(cwd, config)) do
    for _, server in ipairs(PluginContents.mcp_servers(entry.path)) do
      if not Toml.is_bare_key(server.name) then
        table.insert(problems, string.format("%s (server %q)", entry.name, server.name))
      elseif not seen[server.name] then
        seen[server.name] = true
        append_server(args, server)
        -- The bundled server's name is read from its manifest rather than hard-coded, so a
        -- rename there cannot leave the model told about a server that is not registered.
        if entry.path == self_dir and not self_server then
          self_server = server.name
        end
      end
    end
    for _, skill in ipairs(PluginContents.skills(entry.path)) do
      table.insert(skills, { plugin = entry.name, skill = skill })
    end
  end

  warn_once(cwd, problems)

  local instructions = developer_instructions(skills, self_server, rpc_port)
  if instructions then
    -- One override, one flag: `-c` replaces a `developer_instructions` the user set in their own
    -- config.toml for the duration of the run. Accepted -- codex offers no additive form
    -- (`additional_developer_instructions` is rejected under `--strict-config`).
    override(args, "developer_instructions", Toml.string(instructions))
  end

  return args
end

return M
