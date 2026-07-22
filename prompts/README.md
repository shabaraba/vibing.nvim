# Prompts Directory

This directory contains prompt templates used by vibing.nvim features.

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
