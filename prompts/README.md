# Prompts Directory

This directory contains prompt templates used by vibing.nvim features.

`daily_summary.md` and `chat_summary.md` are the only prompts loaded from here. Every other prompt
vibing.nvim sends — including the system prompt appended to each turn — is built inline in
`lua/vibing/infrastructure/adapter/modules/cli_command_builder.lua`. Adding a file to this
directory does not make it take effect; it has to be loaded via `PromptLoader.load` from Lua.

## Available Prompts

### `daily_summary.md`

Prompt template for generating daily development summaries.

**Variables:**

- `{{date}}` - Target date (YYYY-MM-DD format)
- `{{language_instruction}}` - Language-specific instruction (optional)
- `{{conversations}}` - Formatted conversation history

**Usage:**
Automatically loaded by `VibingDailySummary` command.

**Customization:**
You can customize this prompt by editing the file. The format follows engineering best practices:

- YWT (やったこと/わかったこと/つぎにやること) format
- Project-based grouping
- Actionable next steps with checkboxes
- Specific technical details

**References:**

- [The Pragmatic Engineer - Work Log Template](https://blog.pragmaticengineer.com/work-log-template-for-software-engineers/)
- [A Software Engineer's Guide to Journaling](https://medium.com/@aayushuppal/a-software-engineers-guide-to-journaling-f2364162d96d)
- [エンジニア向け日報作成ガイド](https://teams.qiita.com/daily-report-creation-guide-for-engineers/)

### `chat_summary.md`

Prompt template for `:VibingSummarize` — the `## summary` block written into the chat file's own
header, between `# Vibing Chat` and the first `---`.

**Variables:**

- `{{conversation}}` - The chat's User/Assistant messages, each wrapped in `<message role="...">`
  inside a single `<conversation>` element

**Usage:**
Loaded by `use_case._build_summary_prompt`, reached from `:VibingSummarize`. The `/summarize` slash
command is a different path with its own inline prompt (`application/chat/handlers/summarize.lua`)
and is unaffected by this file.

**Customization:**
The section headings, their emojis, and the output language are part of the template, so editing this
file changes them. Unlike `daily_summary.md`, this template does not take a
`{{language_instruction}}` variable — it pins Japanese, and `config.language` is not consulted.

The emojis sit on the `###` headings only. `## summary` deliberately has none: `prepare_summary_lines`
matches that first line as `^##%s*summary`, so an emoji there fails the check and the whole summary is
thrown away rather than degrading. The `#### 決定:` blocks are entries rather than sections, and are
left bare so a chat with three decisions does not repeat the same glyph three times.

What is **not** free to change is the heading shape: `## summary` first, `###` or deeper after it, no
bare `---`. Those three are a format contract with the parser, stated for the model in the
template's rules and explained where it is enforced — `presentation/chat/modules/summary_inserter.lua`, above
`find_summary_section`. Loosen the parser first.

**Why it is a decision log rather than a work log:**
`daily_summary.md` answers "what happened today"; this one answers "what did we decide and what did we
reject". Decisions worth promoting past one chat get an `ADR候補: あり` marker; the actual record then
goes to `handbook/adr/` via the `adr` skill, which owns the numbering and status lifecycle.

## Adding New Prompts

1. Create a new `.md` file in this directory
2. Use `{{variable_name}}` syntax for variables
3. Load it using `require("vibing.core.utils.prompt_loader").load("prompt_name", { variable_name = "value" })`

Example:

```lua
local PromptLoader = require("vibing.core.utils.prompt_loader")
local prompt, err = PromptLoader.load("my_prompt", {
  user_name = "Alice",
  task_description = "Fix bug #123",
})
```

## Prompt Loader API

```lua
---@param prompt_name string Name of the prompt file (without .md extension)
---@param replacements? table<string, string> Variable replacements
---@return string|nil content Loaded prompt content
---@return string|nil error Error message if loading failed
function PromptLoader.load(prompt_name, replacements)
```
