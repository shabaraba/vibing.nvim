--- Put the user's Codex provider back on a lightweight call.
---
--- Lightweight calls run with `--ignore-user-config` because that is the only flag that keeps
--- them out of the user's MCP servers (`codex_command_builder.lua`). The same flag drops
--- `model_provider` and `model`, so a title or summary went to Codex's compiled-in OpenAI default
--- even when ordinary chat used a custom or local provider (#925).
---
--- Codex reports the provider's name (`codex doctor`) and not its definition, so the definition
--- comes from `$CODEX_HOME/config.toml`. Only the top-level `model_provider`, `model` and
--- `openai_base_url`, plus the selected `[model_providers.<id>]` table, are copied back as `-c`
--- overrides; MCP servers, profiles and hooks stay out.
---
--- The provider is copied whole or not at all. A table this copy cannot reproduce, a legacy
--- `profile` key, or a provider that carries `experimental_bearer_token` (which would put a
--- secret on the argv, readable through `ps`) yields no overrides, so the call keeps today's
--- route and `codex_provider_notice` still describes it.
---
--- @module vibing.infrastructure.adapter.modules.codex_lightweight_provider

local NonClaudeModel = require("vibing.infrastructure.adapter.modules.non_claude_model")
local Toml = require("vibing.core.utils.toml")
local TomlAssignments = require("vibing.core.utils.toml_assignments")

local M = {}

--- A config past this is not a provider definition; skip the copy rather than stall a title.
local MAX_BYTES = 512 * 1024

--- Codex's own default. Naming it explicitly changes nothing, so it is not re-sent.
local DEFAULT_PROVIDER = "openai"

--- nil reads the real `$CODEX_HOME/config.toml`; false reads nothing. Test seam.
--- @type string|false|nil
local path_override

function M._reset()
  path_override = nil
end

--- @param path string|false
function M._set_config_path(path)
  path_override = path
end

--- @return Vibing.TomlAssignment[]|nil
local function read_config()
  if path_override == false then
    return nil
  end
  local home = vim.env.CODEX_HOME
  home = (home and home ~= "") and home:gsub("/+$", "") or vim.fn.expand("~/.codex")
  local path = path_override or (home .. "/config.toml")
  local size = vim.fn.getfsize(path)
  if size < 0 or size > MAX_BYTES then
    return nil
  end
  local ok, lines = pcall(vim.fn.readfile, path)
  return ok and TomlAssignments.scan(lines) or nil
end

--- The selected provider's `-c` pairs, or nil when the table cannot travel whole.
--- @param entries Vibing.TomlAssignment[]
--- @param provider string
--- @return string[]|nil
local function provider_overrides(entries, provider)
  local pairs_by_key = {}
  for _, entry in ipairs(entries) do
    local path = entry.path
    if path[1] == "model_providers" and path[2] == provider then
      local key = table.concat(path, ".")
      local bare = vim.iter(path):all(Toml.is_bare_key)
      if not (entry.raw and bare) or path[3] == "experimental_bearer_token" then
        return nil
      end
      pairs_by_key[key] = entry.raw
    end
  end
  local keys = vim.tbl_keys(pairs_by_key)
  table.sort(keys)
  return vim.tbl_map(function(key)
    return key .. "=" .. pairs_by_key[key]
  end, keys)
end

--- `-c` overrides that put the configured provider and model back on one lightweight call.
---
--- `model` is included only when this call passes no `-m`: a configured `ai.helpers.model`
--- (anything other than a Claude short name) wins, on the same provider.
--- @param ctx Vibing.RequestContext
--- @return string[]
function M.args(ctx)
  local entries = read_config() or {}
  local root = {}
  for _, entry in ipairs(entries) do
    if #entry.path == 1 then
      root[entry.path[1]] = TomlAssignments.decode_string(entry.raw) or true
    end
  end
  if root.profile then
    return {}
  end

  local overrides = {}
  local provider = root.model_provider
  if type(provider) == "string" and provider ~= "" and provider ~= DEFAULT_PROVIDER then
    local definition = Toml.is_bare_key(provider) and provider_overrides(entries, provider)
    if not definition then
      return {}
    end
    overrides = vim.list_extend({ "model_provider=" .. Toml.string(provider) }, definition)
  end
  if type(root.openai_base_url) == "string" and root.openai_base_url ~= "" then
    table.insert(overrides, "openai_base_url=" .. Toml.string(root.openai_base_url))
  end
  if type(root.model) == "string" and root.model ~= "" and not NonClaudeModel.resolve(ctx.opts, ctx.config) then
    table.insert(overrides, "model=" .. Toml.string(root.model))
  end

  local args = {}
  for _, override in ipairs(overrides) do
    vim.list_extend(args, { "-c", override })
  end
  return args
end

return M
