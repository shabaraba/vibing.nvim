local notify = require("vibing.core.utils.notify")
local Git = require("vibing.core.utils.git")
local PromptTemplate = require("vibing.domain.chat.prompt_template")

---@param args string[]
---@param chat_buffer Vibing.ChatBuffer
---@return boolean handled
---@return string? draft
return function(args, chat_buffer)
  if #args == 0 then
    notify.warn("/template <task description>", "Usage")
    return false
  end

  local task_description = table.concat(args, " ")
  local git_root = Git.get_root()

  local context_lines = {}

  local cwd = chat_buffer:get_cwd() or vim.fn.getcwd()
  table.insert(context_lines, "- リポジトリ: " .. Git.to_display_path(cwd, git_root))

  local has_claude_md = (git_root ~= nil and vim.fn.filereadable(git_root .. "/CLAUDE.md") == 1)
    or vim.fn.filereadable(vim.fn.expand("~/.claude/CLAUDE.md")) == 1
  if has_claude_md then
    table.insert(context_lines, "- 既存の規約: CLAUDE.mdに従う")
  end

  local draft, err = PromptTemplate.build(task_description, context_lines)
  if not draft then
    notify.error(string.format("Failed to build template: %s", err))
    return false
  end

  return true, draft
end
