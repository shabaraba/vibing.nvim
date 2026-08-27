--- File contents for a project-local Claude Code plugin.
---
--- Kept apart from `scaffold.lua` so the writer stays about paths and failure handling while
--- this stays about what a correct plugin looks like.
--- @module vibing.infrastructure.plugins.scaffold_files

local M = {}

--- Name of the template directory under `.vibing/plugins/`.
---
--- The leading underscore is load-bearing: `plugin_dirs` skips those, so the template ships a
--- complete example without its skill description riding along in every request's system prompt
--- and without showing up in the `/` picker. Copy it to a plain name to turn it on.
M.TEMPLATE_DIR = "_template"

--- Written by hand rather than through `vim.json.encode`, which emits one unindented line with
--- the keys in table order. This file is meant to be edited.
--- @param name string plugin name
--- @return string
local function plugin_json(name)
  return table.concat({
    "{",
    string.format('  "name": %s,', vim.json.encode(name)),
    string.format('  "description": %s,', vim.json.encode("Project-local plugin: " .. name .. ".")),
    '  "version": "0.1.0"',
    "}",
    "",
  }, "\n")
end

--- @param name string
--- @return string
local function skill(name)
  return table.concat({
    "---",
    "name: example",
    "description: Use when you need a worked example of a project-local skill. Replace this"
      .. " description with the situation that should pull the skill in - Claude reads only"
      .. " this line when deciding whether to load the body, so name the trigger, not the topic.",
    "---",
    "",
    "# Example skill",
    "",
    string.format("This file lives in `.vibing/plugins/%s/skills/example/SKILL.md`.", name),
    "",
    "Everything below the frontmatter is loaded only once the description above matches what the",
    "user is doing. Put the actual instructions here: the steps to follow, the commands to run,",
    "the conventions of this repository that Claude cannot infer from the code.",
    "",
    "## Replace this",
    "",
    "1. Rewrite `description` so it states *when* to use the skill.",
    "2. Rewrite this body with the procedure worth repeating.",
    "3. Run `:VibingReloadCommands` and type `/` in a chat - the skill appears as",
    string.format("   `%s:example`.", name),
    "",
  }, "\n")
end

--- @param name string
--- @return string
local function agent(name)
  return table.concat({
    "---",
    "name: example-agent",
    "description: Use when a task should run in its own context window with a narrower brief than"
      .. " the main conversation. Replace this with the kind of work this agent should be handed.",
    "model: sonnet",
    "---",
    "",
    "You are a subagent defined by a project-local plugin.",
    "",
    string.format("This file lives in `.vibing/plugins/%s/agents/example-agent.md`.", name),
    "",
    "Describe here what the agent should do, what it must not do, and what its final message",
    "should contain - that message is the only thing the caller receives.",
    "",
  }, "\n")
end

--- @param name string
--- @return string
local function readme(name)
  return table.concat({
    string.format("# %s", name),
    "",
    "A project-local Claude Code plugin, loaded by vibing.nvim through `--plugin-dir`.",
    "",
    "```",
    string.format("%s/", name),
    "├── .claude-plugin/plugin.json   required - a directory without it is silently ignored",
    "├── skills/<skill>/SKILL.md      shows up in the chat's `/` completion",
    "└── agents/<agent>.md            shows up as a subagent",
    "```",
    "",
    "Also honoured by Claude Code, though vibing.nvim's `/` completion does not list them:",
    "`commands/`, `hooks/`, and an `mcpServers` block in `plugin.json`.",
    "",
    "## After editing",
    "",
    "Run `:VibingReloadCommands`. Directory contents are read per request, but the resolved",
    "plugin list and the completion cache are not.",
    "",
    "## Troubleshooting",
    "",
    "`--plugin-dir` ignores a broken plugin without saying so, so vibing.nvim checks the manifest",
    "itself and warns. If a change seems to have no effect, check that `plugin.json` still parses",
    "and still has a `name`.",
    "",
  }, "\n")
end

--- Files that make up one plugin, relative to the plugin directory.
--- @param name string plugin name
--- @return table<string, string> relative path -> contents
function M.plugin(name)
  return {
    [".claude-plugin/plugin.json"] = plugin_json(name),
    ["README.md"] = readme(name),
    ["skills/example/SKILL.md"] = skill(name),
    ["agents/example-agent.md"] = agent(name),
  }
end

return M
