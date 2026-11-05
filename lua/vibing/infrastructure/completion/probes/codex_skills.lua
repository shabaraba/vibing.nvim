--- Ask `codex app-server` which skills it loads for a directory.
---
--- Codex has no slash-command list to ask for; its menu is its skills. `skills/list` answers per
--- directory with the repo, user and system (bundled) skills, and starts no thread, so nothing is
--- sent to the model. Measured 2026-11-05 on codex-cli 0.166.0: ~120ms.
--- @module vibing.infrastructure.completion.probes.codex_skills

local LineJob = require("vibing.infrastructure.completion.probes.line_job")

local M = {}

local INITIALIZE_ID = 1
local SKILLS_LIST_ID = 2

--- What each `scope` of a codex skill is called in the menu's second column.
local SOURCE_BY_SCOPE = { repo = "project", user = "user", system = "bundled" }

--- @param result any
--- @return Vibing.CliCommand[]?
local function skills_of(result)
  local entry = type(result) == "table" and type(result.data) == "table" and result.data[1] or nil
  if type(entry) ~= "table" or type(entry.skills) ~= "table" then
    return nil
  end

  local commands = {}
  for _, skill in ipairs(entry.skills) do
    if type(skill) == "table" and type(skill.name) == "string" and skill.enabled ~= false then
      table.insert(commands, {
        name = skill.name,
        description = skill.description,
        source = SOURCE_BY_SCOPE[skill.scope],
      })
    end
  end
  return commands
end

--- @param opts { argv: string[], cwd: string, timeout_ms: integer? }
--- @param callback fun(commands: Vibing.CliCommand[]?)
--- @return boolean started
function M.fetch(opts, callback)
  return LineJob.run({
    argv = opts.argv,
    cwd = opts.cwd,
    timeout_ms = opts.timeout_ms,
    start = function(send)
      send({
        id = INITIALIZE_ID,
        method = "initialize",
        params = { clientInfo = { name = "vibing_nvim", title = "vibing.nvim", version = "5.9.0" } },
      })
    end,
    on_message = function(message, send, finish)
      if message.id == INITIALIZE_ID then
        if message.error ~= nil then
          finish(nil)
          return
        end
        send({ method = "initialized" })
        send({ id = SKILLS_LIST_ID, method = "skills/list", params = { cwds = { opts.cwd } } })
      elseif message.id == SKILLS_LIST_ID then
        finish(message.error == nil and skills_of(message.result) or nil)
      end
    end,
  }, callback)
end

return M
