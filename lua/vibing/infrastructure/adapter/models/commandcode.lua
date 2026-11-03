--- Which models the Command Code CLI would accept, asked of the CLI.
--- @module vibing.infrastructure.adapter.models.commandcode

local M = {}

function M.command(config)
  local path = vim.tbl_get(config or {}, "ai", "agents", "commandcode", "path")
  if type(path) == "string" and path ~= "" then
    return { vim.fn.expand(path), "--list-models" }
  end
  return { "commandcode", "--list-models" }
end

--- Read the model ids out of `commandcode --list-models`.
---
--- The output is grouped under bare headings (`Open Source`, `Anthropic`, …) and every model is one
--- line of `id` padded with whitespace then a description. A heading is a line with no leading
--- whitespace-separated id column, so the id is matched by shape — `a/b` or `a-b-c` with no spaces —
--- rather than by tracking the sections, which is what keeps a new section from hiding its models.
--- @param stdout string
--- @return Vibing.AgentModelCandidate[]
function M.parse(stdout)
  local candidates = {}
  local seen = {}
  for _, line in ipairs(vim.split(stdout or "", "\n", { plain = true })) do
    local id, rest = line:match("^%s*(%S+)%s%s+(.*)$")
    if not id and line:match("^%s*%S+%s*$") then
      id, rest = line:match("^%s*(%S+)%s*$"), ""
    end
    -- Shape guard: a heading ("Open Source") has a space, the summary line starts with a word, and
    -- neither looks like a model id. Every real id passes — `deepseek/deepseek-v4-pro`,
    -- `claude-sonnet-5-5`, and the `:free` tier suffix (`reflection/beam:free`) — while
    -- `Available`, `models`, `·`, `95` and a `Docs:` heading do not (each ends in a character the
    -- class excludes, which is what keeps a heading that happens to read like a slug out).
    if
      id
      and id:match("^[%w][%w%-%._/:]*[%w]$")
      and not id:match("^%d+$")
      and (id:find("/", 1, true) or id:find("-", 1, true))
      and not seen[id]
    then
      seen[id] = true
      rest = vim.trim(rest or "")
      table.insert(candidates, { value = id, description = rest ~= "" and rest or "Available in the Command Code CLI" })
    end
  end
  return candidates
end

return M
