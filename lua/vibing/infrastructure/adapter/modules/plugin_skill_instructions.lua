--- The plugin-skill listing for backends that deliver skills as prompt text.
---
--- Claude gets skills through `--plugin-dir` and Command Code's oneshot transport through
--- `--skill`; both make them real slash commands. The other channels (Codex's
--- `developer_instructions`, Command Code's ACP session prompt) can only describe them, so the
--- listing also tells the model what a leading `/name` means there — measured on Command Code
--- 1.88.2: without that sentence the model answered "isn't a command I recognize", and with it it
--- read the SKILL.md and followed it.
--- @module vibing.infrastructure.adapter.modules.plugin_skill_instructions

local M = {}

--- @param skills {plugin: string, skill: Vibing.PluginSkill}[]
--- @return string[]
function M.lines(skills)
  if #skills == 0 then
    return {}
  end

  local lines = {
    "vibing.nvim has loaded plugin skills for this session. A skill is a set of local "
      .. "instructions stored in a SKILL.md file. When a task matches a skill's description, "
      .. "read that file with your shell (it is readable inside the sandbox) and follow it.",
    "When a message begins with /<skill-name> naming one of them, treat it as that skill: read "
      .. "its SKILL.md and follow it.",
    "Available plugin skills:",
  }
  for _, item in ipairs(skills) do
    table.insert(lines, string.format("- %s:%s: %s", item.plugin, item.skill.name, item.skill.description))
    table.insert(lines, "  SKILL.md: " .. item.skill.path)
  end
  return lines
end

--- Every skill the resolved plugin directories bundle, in the order Codex lists them.
--- @param cwd string|nil
--- @param config Vibing.Config
--- @return {plugin: string, skill: Vibing.PluginSkill}[]
function M.collect(cwd, config)
  local PluginDirs = require("vibing.infrastructure.plugins.plugin_dirs")
  local PluginContents = require("vibing.infrastructure.plugins.plugin_contents")

  local skills = {}
  for _, entry in ipairs(PluginDirs.resolve_entries(cwd, config)) do
    for _, skill in ipairs(PluginContents.skills(entry.path)) do
      table.insert(skills, { plugin = entry.name, skill = skill })
    end
  end
  return skills
end

return M
