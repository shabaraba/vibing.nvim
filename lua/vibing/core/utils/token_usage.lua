--- Per-turn token accounting.
---
--- What this exists to make visible: a turn costs (requests x context size), not reply length.
--- Every tool call is another API request, and every request re-reads the whole conversation --
--- so one turn with ten tool calls in a 200k chat reads 2M tokens. Nothing in the buffer said so,
--- and auto-compaction does not help: it fires near the model's context ceiling (measured at
--- ~930k in this project's own logs), so it is a survival mechanism, not a cost control. By the
--- time it runs, every request on the way up has already been paid for at the larger size.
---
--- @module vibing.core.utils.token_usage

local M = {}

--- Context size at or above which a chat is worth splitting.
---
--- Measured over 30 days of this project's own session logs: the rate at which a request fails to
--- reuse the prefix cache -- and re-writes an identical prefix at cache-creation price -- tracks
--- context size directly (0% under 30k, 1.1% at 30-80k, 4.8% at 80-150k, 6.9% above). Above the
--- threshold both the per-request read and the odds of paying for a rewrite are working against
--- you, so this is where doing something about the size starts paying for itself.
M.DEFAULT_WARN_CONTEXT = 150000

--- Context size at or above which an opt-in `/compact` is worth paying for.
---
--- Above `DEFAULT_WARN_CONTEXT` on purpose. The warning is the reader's own decision point, and
--- compaction is not free: the turn after it re-writes the whole prefix (measured at 79,783
--- tokens of new cache on a small session), so a threshold that fired at the same place the
--- warning appears would take that decision away at the exact moment it is being offered.
M.DEFAULT_AUTO_COMPACT_AT = 200000

--- Age at which a chat's prompt cache is treated as gone.
---
--- Claude Code's prompt cache lives for one hour on a subscription plan, so a chat resumed after
--- lunch rewrites everything from the system prompt to the transcript at cache-creation price --
--- 12.5x the read price, against an input side that is ~89% of the bill. The default is 55
--- minutes rather than 60 so a send that lands just inside the hour is still caught; the TTL is
--- not published in the response, so it can only be inferred from the clock.
M.DEFAULT_CACHE_TTL_SEC = 3300

--- @class Vibing.TokenUsage
--- @field requests number main-chain API requests this turn (one per tool-call round trip)
--- @field subagent_requests number requests made by subagents, which carry their own context
--- @field context number largest main-chain prompt seen this turn -- the chat's current size
--- @field read number cache_read tokens, summed
--- @field write number cache_creation tokens, summed
--- @field first_context number prompt size of the turn's first main-chain request
--- @field first_write number cache_creation on that same request
---
--- Output tokens are deliberately not accumulated. They are ~11% of the bill against the input
--- side's ~89% (measured over 30 days of this project's logs), so putting them next to the
--- numbers that do move the total would invite shortening replies -- which is the one economy
--- here that does not pay.
---
--- The two `first_` fields exist for `prefix_rewrite.lua` and are not displayed. Whether the turn
--- reused the cache is a fact about its **opening** request -- the one that either found the
--- conversation's prefix or did not. The summed `write` cannot answer it: every later request in
--- the turn writes its own increment, so a turn with a dozen tool calls accumulates more `write`
--- than its `context` while hitting the cache every single time. Measured on a real first turn
--- here: context 99k, 9 requests, write 146k.

--- @return Vibing.TokenUsage
function M.new()
  return {
    requests = 0,
    subagent_requests = 0,
    context = 0,
    read = 0,
    write = 0,
    first_context = 0,
    first_write = 0,
  }
end

--- Fold one request's usage into the accumulator.
---
--- Every field is optional and read defensively: the usage object is an undocumented payload from
--- the CLI's stream, so a shape change should cost the indicator rather than the turn.
--- @param acc Vibing.TokenUsage|nil
--- @param usage table|nil
--- @param is_subagent boolean|nil
function M.record(acc, usage, is_subagent)
  if type(acc) ~= "table" or type(usage) ~= "table" then
    return
  end

  local input = tonumber(usage.input_tokens) or 0
  local write = tonumber(usage.cache_creation_input_tokens) or 0
  local read = tonumber(usage.cache_read_input_tokens) or 0

  acc.read = acc.read + read
  acc.write = acc.write + write

  -- A subagent runs in its own, much smaller context (measured at 83k against the main chain's
  -- 208k), so its prompt size says nothing about how big *this* chat has grown. Its tokens are
  -- still real and stay in the totals; only the context gauge excludes it.
  if is_subagent then
    acc.subagent_requests = acc.subagent_requests + 1
    return
  end

  acc.requests = acc.requests + 1
  local context = input + write + read
  if context > acc.context then
    acc.context = context
  end

  if acc.requests == 1 then
    acc.first_context = context
    acc.first_write = write
  end
end

--- @param n number
--- @return string
local function humanize(n)
  -- The boundary is where the k form *rounds* to 1000k, not where the number reaches 1M: the
  -- branch below rounds half-up, so 999,999 would otherwise print as "1000k".
  if n >= 999500 then
    return string.format("%.1fM", n / 1000000)
  end
  if n >= 1000 then
    return string.format("%dk", math.floor(n / 1000 + 0.5))
  end
  return tostring(math.floor(n))
end

--- Token counts in the short form the chat renders them in ("205k", "2.4M").
--- @param n number
--- @return string
M.humanize = humanize

--- @deprecated Use `M.humanize`; kept so existing callers keep working.
M._humanize = humanize

---@class Vibing.CodexTokenTotals
---@field input number cumulative input tokens reported by the Codex thread
---@field cached number cumulative cached-input tokens reported by the Codex thread
---@field cache_write number cumulative cache-write tokens reported by the Codex thread
---@field output number cumulative output tokens reported by the Codex thread
---@field reasoning number cumulative reasoning-output tokens reported by the Codex thread

---@class Vibing.CodexTokenUsage
---@field backend "codex"
---@field totals Vibing.CodexTokenTotals exact cumulative counters carried by `turn.completed`
---@field input number counters to display (normally the delta from the preceding section)
---@field cached number
---@field cache_write number
---@field output number
---@field reasoning number
---@field scope "turn"|"session" whether the displayed counters are a delta or a cumulative total

--- Coerce one counter from an external payload without letting a malformed usage event break the
--- turn footer. Codex's Rust side emits non-negative integers, but custom providers and older CLI
--- versions still cross this boundary, so accept numeric strings and make every other shape zero.
---@param value any
---@return number
local function counter(value)
  local number = tonumber(value)
  if not number or number < 0 or number ~= number or number == math.huge then
    return 0
  end
  return math.floor(number)
end

--- Turn Codex's terminal `turn.completed.usage` payload into the common reporter's tagged value.
---
--- Unlike Claude's stream, Codex exposes one aggregate after the turn, and on a resumed thread the
--- aggregate is cumulative for the session. `M.codex_delta` resolves that cumulative value just
--- before it is written, after the previous footer can be read from the chat buffer.
---@param usage table|nil
---@return Vibing.CodexTokenUsage|nil
function M.from_codex(usage)
  if type(usage) ~= "table" then
    return nil
  end

  local totals = {
    input = counter(usage.input_tokens),
    cached = counter(usage.cached_input_tokens),
    cache_write = counter(usage.cache_write_input_tokens),
    output = counter(usage.output_tokens),
    reasoning = counter(usage.reasoning_output_tokens),
  }
  return {
    backend = "codex",
    totals = totals,
    input = totals.input,
    cached = totals.cached,
    cache_write = totals.cache_write,
    output = totals.output,
    reasoning = totals.reasoning,
    scope = "session",
  }
end

--- Read the exact cumulative Codex counters out of a footer heading written by `M.section`.
--- All fields are required even when zero: accepting a partial marker would make a CLI/schema
--- change look like a valid delta while silently under-counting one token class.
---@param line string
---@return Vibing.CodexTokenTotals|nil
function M.parse_codex_totals(line)
  if type(line) ~= "string" or not line:match("^###%s+Tokens%s+<!%-%-") then
    return nil
  end

  local input = line:match("codex%-input=(%d+)")
  local cached = line:match("codex%-cached=(%d+)")
  local cache_write = line:match("codex%-cache%-write=(%d+)")
  local output = line:match("codex%-output=(%d+)")
  local reasoning = line:match("codex%-reasoning=(%d+)")
  if not input or not cached or not cache_write or not output or not reasoning then
    return nil
  end

  return {
    input = tonumber(input),
    cached = tonumber(cached),
    cache_write = tonumber(cache_write),
    output = tonumber(output),
    reasoning = tonumber(reasoning),
  }
end

--- Find the most recently displayed Codex cumulative counters in a chat.
---
--- This deliberately means "last displayed", not "previous assistant turn". If token display was
--- temporarily disabled, the next difference spans that hidden interval and is still truthful;
--- calling it the current turn would not be. In the ordinary default-on path the two are the same.
---@param lines string[]|nil
---@return Vibing.CodexTokenTotals|nil
function M.find_last_codex_totals(lines)
  if type(lines) ~= "table" then
    return nil
  end
  for index = #lines, 1, -1 do
    local totals = M.parse_codex_totals(lines[index])
    if totals then
      return totals
    end
  end
  return nil
end

--- Resolve cumulative Codex counters to what this footer should display.
---
--- A fresh thread starts at zero, so its first aggregate is already this turn's usage. A resumed
--- thread needs the preceding exact marker. Without one (the first reply after upgrading, for
--- example), the cumulative values remain useful but are explicitly labelled as a session total.
--- Any counter moving backwards means the baseline belongs to a different/reset thread, and takes
--- the same safe cumulative fallback.
---@param usage Vibing.CodexTokenUsage
---@param previous Vibing.CodexTokenTotals|nil
---@param started_fresh_session boolean|nil
---@return Vibing.CodexTokenUsage
function M.codex_delta(usage, previous, started_fresh_session)
  if type(usage) ~= "table" or usage.backend ~= "codex" or type(usage.totals) ~= "table" then
    return usage
  end

  local totals = usage.totals
  local baseline = started_fresh_session == true and {
    input = 0,
    cached = 0,
    cache_write = 0,
    output = 0,
    reasoning = 0,
  } or previous

  local fields = { "input", "cached", "cache_write", "output", "reasoning" }
  if type(baseline) == "table" then
    for _, field in ipairs(fields) do
      if type(baseline[field]) ~= "number" or totals[field] < baseline[field] then
        baseline = nil
        break
      end
    end
  end

  local resolved = {
    backend = "codex",
    totals = totals,
    scope = baseline and "turn" or "session",
  }
  for _, field in ipairs(fields) do
    resolved[field] = totals[field] - (baseline and baseline[field] or 0)
  end
  return resolved
end

--- Read the `context` figure back out of a written `### Tokens` section.
---
--- The accumulator is thrown away when the turn ends, so the section text is the only record of
--- how big the chat was -- and it has to survive a Neovim restart, which rules out keeping the
--- number in memory. The heading therefore carries the exact figure in a marker comment, the
--- same trick the section headers already use (`## User <!-- ... -->`), and that is what this
--- reads.
---
--- The humanized metrics line is accepted as a fallback so chats written before the marker
--- existed still answer. That path is lossy in `humanize`'s own direction -- it rounds half-up,
--- so a chat at 149,600 reads back as exactly 150k -- which is precisely why the marker exists
--- rather than being the only form.
--- @param line string a `### Tokens` heading, or its metrics line
--- @return number|nil
function M.parse_context(line)
  if type(line) ~= "string" then
    return nil
  end

  local exact = line:match("^###%s+Tokens%s+<!%-%-%s*context=(%d+)%s*%-%->")
  if exact then
    return tonumber(exact)
  end

  local digits, suffix = line:match("^%s*context ([%d%.]+)([kM]?)")
  local value = digits and tonumber(digits)
  if not value then
    return nil
  end

  if suffix == "k" then
    value = value * 1000
  elseif suffix == "M" then
    value = value * 1000000
  end
  return math.floor(value)
end

--- The metrics themselves, as one line, or nil when there is nothing to report.
--- @param acc Vibing.TokenUsage|nil
--- @return string|nil
function M.format(acc)
  if type(acc) == "table" and acc.backend == "codex" then
    if type(acc.totals) ~= "table" then
      return nil
    end
    local prefix = acc.scope == "session" and "session " or ""
    local parts = {
      prefix .. "input " .. humanize(acc.input) .. " (cached " .. humanize(acc.cached) .. ")",
      "output " .. humanize(acc.output) .. " (reasoning " .. humanize(acc.reasoning) .. ")",
    }
    if (acc.cache_write or 0) > 0 then
      table.insert(parts, "cache write " .. humanize(acc.cache_write))
    end
    return table.concat(parts, " · ")
  end

  if type(acc) ~= "table" or (acc.requests or 0) == 0 then
    return nil
  end

  local parts = {
    "context " .. humanize(acc.context),
    string.format("%d request%s", acc.requests, acc.requests == 1 and "" or "s"),
    "read " .. humanize(acc.read),
    "new " .. humanize(acc.write),
  }
  if (acc.subagent_requests or 0) > 0 then
    table.insert(parts, string.format("%d subagent", acc.subagent_requests))
  end

  return table.concat(parts, " · ")
end

--- The warning to write under the metrics, or nil when the chat is still small enough.
---
--- Written into the buffer on **every** turn above the threshold rather than once when it is
--- crossed, and that is the whole point of it living here instead of in `vim.notify`: a
--- notification is gone by the time the next turn is read, so the one moment the reader is
--- actually looking at the cost -- the lines above this one -- would say nothing. Repetition is
--- what makes it a gauge; keeping it to three lines is what keeps it from being noise.
---
--- It names `/compact` and `:VibingChatHandoff`, and deliberately not `/summarize`. `/summarize`
--- shows a summary in a floating window and never touches the session, so the turn after it
--- re-reads exactly as much as the turn before. `:VibingChatHandoff` starts a new chat carrying
--- only the summary, which is the cheaper of the two once the cache has gone cold (a cold
--- `/compact` re-reads the whole conversation at creation price before it can summarize it).
--- The CLI's own `/compact` does shrink the conversation, and it is reachable
--- from a chat because an unrecognised slash command falls through as prompt text -- verified
--- against claude 2.1.231 in headless `-p` mode, which emits a `compact_boundary` and carries the
--- same session on afterwards.
--- @param context number
--- @param warn_context number
--- @return string|nil
function M.warning(context, warn_context)
  if not warn_context or warn_context <= 0 or (context or 0) < warn_context then
    return nil
  end

  return string.format(
    "> ⚠️ **Context is %s.** Every tool call re-reads all of it, and above %s a request grows\n"
      .. "> likelier to re-pay for a prefix it had already cached. Consider `/compact`,\n"
      .. "> `:VibingChatHandoff` to continue in a new chat from a summary, or handing the\n"
      .. "> exploring to a subagent.",
    humanize(context),
    humanize(warn_context)
  )
end

--- The floor this chat starts every turn from, or nil when the CLI did not say.
---
--- Shown once, on a session's first turn, because that is the one turn whose context *is* the
--- floor: nothing has been said yet, so the prompt is the system prompt, the tool schemas and
--- the memory files and nothing else. #669 could only put a number on it by hand.
---
--- The caller must pass `acc.first_context`, not `acc.context`. Only the turn's **opening**
--- request carries nothing but the floor; the moment that turn calls a tool, every request after
--- it also carries the tool results the turn itself produced, and `acc.context` is the largest of
--- those. A first turn of two requests is ordinary, so reading the maximum would overstate the
--- floor on most sessions -- and the number would still look plausible, which is what makes it
--- worth naming here.
--- @param context number the opening request's prompt size (`Vibing.TokenUsage.first_context`)
--- @param cli_info { tools: number|nil, mcp_servers: number|nil }|nil
--- @return string|nil
function M.floor(context, cli_info)
  if type(cli_info) ~= "table" or (context or 0) <= 0 then
    return nil
  end

  local parts = {}
  if type(cli_info.tools) == "number" then
    table.insert(parts, string.format("%d tools", cli_info.tools))
  end
  if type(cli_info.mcp_servers) == "number" then
    table.insert(parts, string.format("%d MCP servers", cli_info.mcp_servers))
  end
  if #parts == 0 then
    return nil
  end

  return string.format("floor ~%s (%s)", humanize(context), table.concat(parts, ", "))
end

--- The whole `### Tokens` section for the chat buffer, or nil for a turn with nothing to report.
---
--- A section rather than a stray italic line so it sits at the same level as `### Modified Files`
--- -- the two are the same kind of thing, a per-turn footer about what the turn did, and a reader
--- scanning headings should find the cost as readily as the file list.
---
--- Claude's heading carries the exact context size in a marker comment. The visible line is
--- rounded for reading, and the pre-send cache gate (`application/chat/cache_expiry`) and the
--- auto-compact gate (`application/chat/auto_compact`) both need to compare the real figure against
--- a threshold after a restart, when nothing but this text is left. Codex instead carries exact
--- cumulative counters so the next turn can derive a delta. Renaming or reordering either visible
--- line is safe; dropping its marker is not, and neither is putting anything ahead of the heading.
---
--- The rewrite note comes before the context warning: it says what this turn actually did, while
--- the warning is standing advice that repeats on every large turn.
--- @param acc Vibing.TokenUsage|Vibing.CodexTokenUsage|nil
--- @param warn_context number|nil
--- @param extras { floor: string|nil, rewrite: string|nil }|nil
--- @return string|nil
function M.section(acc, warn_context, extras)
  local line = M.format(acc)
  if not line then
    return nil
  end

  if acc.backend == "codex" then
    local totals = acc.totals
    local section = string.format(
      "### Tokens <!-- codex-input=%d codex-cached=%d codex-cache-write=%d codex-output=%d codex-reasoning=%d -->\n\n%s\n",
      totals.input,
      totals.cached,
      totals.cache_write,
      totals.output,
      totals.reasoning,
      line
    )
    if acc.scope == "session" then
      section = section
        .. "\n> ℹ️ **Session total.** Per-turn deltas start with the next Codex reply.\n"
    end
    return section
  end

  extras = extras or {}
  if extras.floor then
    line = line .. "\n" .. extras.floor
  end

  -- Appended one at a time rather than collected into a list and iterated: a nil rewrite note
  -- would leave a hole at index 1, and `ipairs` stops at the first one -- silently dropping the
  -- context warning on every turn that did not also rewrite its prefix.
  local section = string.format("### Tokens <!-- context=%d -->\n\n", acc.context) .. line .. "\n"
  if extras.rewrite then
    section = section .. "\n" .. extras.rewrite .. "\n"
  end
  local warning = M.warning(acc.context, warn_context)
  if warning then
    section = section .. "\n" .. warning .. "\n"
  end

  return section
end

return M
