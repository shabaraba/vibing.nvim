--- Reading a claude subagent's own transcript back off disk.
---
--- Only the recovery path needs this. When the CLI delivers a `task_notification` the subagent's
--- answer reaches the model through the notification itself; when it drops one (upstream
--- anthropics/claude-code#87675) the transcript is the only copy left.
--- @module vibing.infrastructure.adapter.modules.claude_subagent_transcript

local M = {}

--- Where the CLI keeps a subagent's own transcript.
---
--- Documented layout (`code.claude.com/docs/en/sub-agents`):
--- `~/.claude/projects/<slug>/<session_id>/subagents/agent-<task_id>.jsonl`, where the slug is the
--- project directory with every non-alphanumeric run replaced by `-`. Derived rather than
--- remembered, because a task that was never notified never told us its `output_file`.
--- @param cwd string
--- @param session_id string
--- @param task_id string
--- @return string
function M.path(cwd, session_id, task_id)
  local slug = vim.fn.fnamemodify(cwd, ":p"):gsub("/$", ""):gsub("[^%w]", "-")
  return string.format("%s/.claude/projects/%s/%s/subagents/agent-%s.jsonl", vim.env.HOME, slug, session_id, task_id)
end

--- @param line string one JSONL entry
--- @return string? the last non-empty text block of an assistant entry
local function assistant_text(line)
  local ok, entry = pcall(vim.json.decode, line)
  if not ok or type(entry) ~= "table" or entry.type ~= "assistant" then
    return nil
  end
  local content = type(entry.message) == "table" and entry.message.content
  if type(content) ~= "table" then
    return nil
  end
  for i = #content, 1, -1 do
    local block = content[i]
    if type(block) == "table" and block.type == "text" and type(block.text) == "string" and block.text ~= "" then
      return block.text
    end
  end
  return nil
end

--- The last thing a subagent said.
---
--- Scanned from the end, because the answer is the last thing in the file and a subagent's
--- transcript is mostly tool traffic. The substring test is a prefilter only — a `user` entry
--- that happens to contain the word still gets decoded and rejected.
---
--- Returns nil rather than an empty string when there is nothing to recover: a transcript that has
--- not been written, a file we cannot read, a run that produced no prose. The caller reports only
--- what it actually found, because "a subagent finished and here is nothing" is worse than saying
--- nothing at all.
--- @param path string
--- @return string?
function M.last_text(path)
  if vim.fn.filereadable(path) ~= 1 then
    return nil
  end
  local lines = vim.fn.readfile(path)
  for i = #lines, 1, -1 do
    if lines[i]:find("assistant", 1, true) then
      local text = assistant_text(lines[i])
      if text then
        return text
      end
    end
  end
  return nil
end

--- @class Vibing.RecoveredSubagent
--- @field task_id string which unreported task this is the answer to. The notice subtracts these
---   from the outstanding set by id, so it can ask about only the ones still owed an answer.
--- @field text string what the subagent said
---
--- Deliberately no display label: the launch's own `description` is already on the
--- `Vibing.BackgroundTask` this answers, and naming the block is the chat layer's job
--- (`.claude/rules/architecture.md` — a decoder holds no rendering).

--- Recover what each unreported subagent said, dropping the ones with nothing to show.
--- @param unreported Vibing.BackgroundTask[]
--- @param cwd string
--- @param session_id string? no session id means no directory to look in, and guessing one would
--- read another conversation's subagents
--- @return Vibing.RecoveredSubagent[]
function M.recover(unreported, cwd, session_id)
  local out = {}
  if not session_id or session_id == "" then
    return out
  end
  for _, entry in ipairs(unreported) do
    local text = M.last_text(M.path(cwd, session_id, entry.task_id))
    if text then
      table.insert(out, { task_id = entry.task_id, text = text })
    end
  end
  return out
end

return M
