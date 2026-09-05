--- Naming why a turn re-paid for a prefix it had already cached.
---
--- `token_usage.lua` already shows `new` beside `context`; that a turn missed the cache is
--- readable from those two numbers only by someone who knows to compare them. A rewrite costs
--- 12.5x what the same tokens cost to read, so it is worth saying outright -- and the causes are
--- few enough to name. In `claude -p` every turn is a fresh process, so an edit to `CLAUDE.md`
--- or `.claude/rules/` takes effect on the very next turn (interactive mode holds the old copy
--- until `/clear` or `/compact`), which makes this the cause a reader is least likely to guess.
---
--- Everything here is optional and read defensively: a cause it cannot establish is simply not
--- claimed, and a turn with no cause found says so rather than inventing one.
---
--- @module vibing.core.utils.prefix_rewrite

local TokenUsage = require("vibing.core.utils.token_usage")
local When = require("vibing.core.utils.when")

local M = {}

--- Fraction of the *opening request's* prompt that has to be written before the turn counts as a
--- rewrite.
---
--- Measured against `first_write / first_context`, never the turn's summed `write`. The sum grows
--- with every tool call — each later request writes its own increment — so a turn that hit the
--- cache on every request still accumulates more `write` than its `context` if it called enough
--- tools. The opening request is the one that either found the conversation's prefix or did not,
--- and it is the only one whose split answers the question.
---
--- Not configurable, unlike `warn_context`: this is a claim about what happened, not a taste
--- about how noisy to be. A warm opening request writes a few percent of its prompt; a cold one
--- writes essentially all of it. Half is far from both.
M.REWRITE_RATIO = 0.5

--- The prompt cache's time-to-live. Claude Code requests the 1-hour TTL, so a gap longer than
--- this guarantees the next turn starts cold whatever else is true.
M.CACHE_TTL_SECONDS = 3600

--- Files whose contents are part of the cached prefix, relative to the request's working
--- directory. Editing any of them invalidates the project layer and everything after it.
---
--- Nested `CLAUDE.md` files further down the tree are deliberately absent: they are injected as
--- cheap deltas at the end of the conversation and do not break the prefix (measured in #669).
local PROJECT_LAYER = {
  files = { "CLAUDE.md", ".vibing/system-prompt.md" },
  globs = { ".claude/rules/*.md" },
  prefix = "",
}

--- The same thing one layer up. A user-level edit invalidates even earlier than a project one,
--- so leaving it out would report "no likely cause" for the case with the largest blast radius.
--- Named with `~/` so a reader can tell the two layers apart at a glance.
local USER_LAYER = {
  files = { ".claude/CLAUDE.md" },
  globs = { ".claude/rules/*.md" },
  prefix = "~/",
}

--- Name at most this many edited files before summarising the rest, so one `sed -i` across the
--- rules directory does not produce a note longer than the answer it is attached to.
local MAX_NAMED_FILES = 3

--- @param path string
--- @return number|nil mtime_seconds
local function mtime(path)
  local ok, stat = pcall(vim.uv.fs_stat, path)
  if not ok or type(stat) ~= "table" or type(stat.mtime) ~= "table" then
    return nil
  end
  return stat.mtime.sec
end

--- Append one layer's files, edited after `since`, to `out` under their display names.
--- @param root string directory the layer's paths are relative to
--- @param layer { files: string[], globs: string[], prefix: string }
--- @param since number Unix seconds
--- @param out string[]
local function collect_edited(root, layer, since, out)
  local paths = {}
  for _, rel in ipairs(layer.files) do
    table.insert(paths, root .. "/" .. rel)
  end
  for _, glob in ipairs(layer.globs) do
    vim.list_extend(paths, vim.fn.glob(root .. "/" .. glob, true, true))
  end

  for _, path in ipairs(paths) do
    local at = mtime(path)
    if at and at > since then
      table.insert(out, layer.prefix .. (path:gsub("^" .. vim.pesc(root .. "/"), "")))
    end
  end
end

--- Which prompt-source files changed since `since`.
---
--- The only I/O in this module, kept apart from `causes` so the ordering and wording rules stay
--- testable without a filesystem.
--- @param cwd string|nil working directory of the request
--- @param since number Unix seconds
--- @param home string|nil user directory to scan; defaults to the real one, injected by tests
--- @return string[] display names, project files first
function M.edited_prompt_sources(cwd, since, home)
  if type(since) ~= "number" then
    return {}
  end

  local edited = {}

  local project_root = cwd and cwd ~= "" and cwd or nil
  if project_root then
    collect_edited(project_root, PROJECT_LAYER, since, edited)
  end

  -- Skipped when the two coincide, so a chat whose working directory *is* the home directory
  -- does not report the same file twice under two names.
  home = home or vim.uv.os_homedir()
  if home and home ~= project_root then
    collect_edited(home, USER_LAYER, since, edited)
  end

  return edited
end

--- @param names string[]
--- @return string
local function name_files(names)
  if #names <= MAX_NAMED_FILES then
    return table.concat(names, ", ")
  end
  local shown = vim.list_slice(names, 1, MAX_NAMED_FILES)
  return string.format("%s and %d more", table.concat(shown, ", "), #names - MAX_NAMED_FILES)
end

--- Did a recorded field actually change?
---
--- Both sides must be known. A record written before this field existed is indistinguishable
--- from one where the value was genuinely unset, so an unset -> set transition is passed over
--- rather than reported: a missed cause costs a reader one guess, a fabricated one costs trust
--- in every other line here.
--- @param before any
--- @param after any
--- @return boolean
local function changed(before, after)
  return before ~= nil and after ~= nil and before ~= after
end

--- @class Vibing.TurnFacts
--- @field at number Unix seconds the turn finished
--- @field started_at number|nil Unix seconds the turn began, when the CLI's `init` said so
--- @field model string|nil model the CLI reported for the turn
--- @field effort string|nil reasoning effort in force
--- @field version string|nil Claude Code version that ran it
--- @field compacted boolean|nil the turn emitted a `compact_boundary`

--- The likely causes, most decisive first.
---
--- Ordered as the causes were catalogued in #674: elapsed time, then the request's own knobs,
--- then the prompt sources, then compaction, then the CLI itself. All that apply are listed --
--- a long gap and a rules edit are both true often enough that picking one would mislead.
--- @param prev Vibing.TurnFacts previous turn
--- @param current Vibing.TurnFacts this turn
--- @param edited string[] display names from `edited_prompt_sources`
--- @return string[]
function M.causes(prev, current, edited)
  local causes = {}

  -- The gap the cache actually sat idle: the previous turn's end to *this* turn's start. Falling
  -- back to `current.at` costs accuracy in one direction only -- it adds this turn's own duration
  -- to the gap -- so the fallback is used solely when the CLI never said when it started.
  local elapsed = (current.started_at or current.at or 0) - (prev.at or 0)
  if elapsed >= M.CACHE_TTL_SECONDS then
    -- The TTL is spelled out rather than passed through `format_duration`, which would render
    -- the round hour as "1h00m".
    table.insert(
      causes,
      string.format("%s since the last turn (the prompt cache TTL is 1h)", When.format_duration(elapsed))
    )
  end

  if changed(prev.model, current.model) then
    table.insert(causes, string.format("the model changed (%s to %s)", prev.model, current.model))
  end

  if changed(prev.effort, current.effort) then
    table.insert(causes, string.format("the effort changed (%s to %s)", prev.effort, current.effort))
  end

  if #edited > 0 then
    table.insert(causes, string.format("%s edited since the last turn", name_files(edited)))
  end

  if prev.compacted then
    table.insert(causes, "the previous turn compacted the conversation")
  end

  if changed(prev.version, current.version) then
    table.insert(causes, string.format("Claude Code was updated (%s to %s)", prev.version, current.version))
  end

  return causes
end

--- Did this turn rewrite its prefix, and if so why?
---
--- Returns nil without a previous turn to compare against. The first turn of a session writes
--- its whole prefix by definition -- that is the cache being filled, not missed -- and reporting
--- it would make the loudest line in the buffer the one that is never actionable.
--- @param acc Vibing.TokenUsage|nil
--- @param prev Vibing.TurnFacts|nil
--- @param current Vibing.TurnFacts
--- @param cwd string|nil
--- @param home string|nil user directory to scan; defaults to the real one, injected by tests
--- @return { write: number, causes: string[] }|nil
function M.detect(acc, prev, current, cwd, home)
  if type(acc) ~= "table" or type(prev) ~= "table" or type(current) ~= "table" then
    return nil
  end

  local context = acc.first_context or 0
  local write = acc.first_write or 0
  if context <= 0 or write < context * M.REWRITE_RATIO then
    return nil
  end

  return {
    write = write,
    causes = M.causes(prev, current, M.edited_prompt_sources(cwd, prev.at, home)),
  }
end

--- Columns the note wraps at, `> ` included. Matches the hand-wrapped context warning next to it.
local WIDTH = 92

--- Wrap `text` into `> `-prefixed lines.
---
--- Hand-wrapping is not available here the way it is for the fixed context warning: a cause names
--- a file path and two model names, so its length is not known when the string is written.
---
--- Measured with `strdisplaywidth`, not `#`. A byte count is three times the width for every
--- non-ASCII character, so `↻` and `—` alone pull the wrap in, and a project with CJK file names
--- would break its lines at around a third of the intended column.
--- @param text string
--- @return string
local function blockquote(text)
  local lines, current = {}, "> "
  for word in text:gmatch("%S+") do
    if current == "> " then
      current = current .. word
    elseif vim.fn.strdisplaywidth(current .. " " .. word) <= WIDTH then
      current = current .. " " .. word
    else
      table.insert(lines, current)
      current = "> " .. word
    end
  end
  table.insert(lines, current)
  return table.concat(lines, "\n")
end

--- The note to write under the metrics line, or nil when there was no rewrite.
--- @param detection { write: number, causes: string[] }|nil
--- @return string|nil
function M.note(detection)
  if type(detection) ~= "table" then
    return nil
  end

  local head = string.format("↻ **Prefix rewritten (%s).**", TokenUsage.humanize(detection.write))
  local causes = detection.causes or {}

  if #causes == 0 then
    return blockquote(
      head .. " No likely cause found — this turn re-paid creation price for a prefix that "
        .. "nothing on this side explains."
    )
  end

  local label = #causes == 1 and "Likely cause:" or "Likely causes:"
  return blockquote(head .. " " .. label .. " " .. table.concat(causes, "; ") .. ".")
end

return M
