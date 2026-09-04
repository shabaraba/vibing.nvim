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

--- @class Vibing.TokenUsage
--- @field requests number main-chain API requests this turn (one per tool-call round trip)
--- @field subagent_requests number requests made by subagents, which carry their own context
--- @field context number largest main-chain prompt seen this turn -- the chat's current size
--- @field read number cache_read tokens, summed
--- @field write number cache_creation tokens, summed
---
--- Output tokens are deliberately not accumulated. They are ~11% of the bill against the input
--- side's ~89% (measured over 30 days of this project's logs), so putting them next to the
--- numbers that do move the total would invite shortening replies -- which is the one economy
--- here that does not pay.

--- @return Vibing.TokenUsage
function M.new()
  return {
    requests = 0,
    subagent_requests = 0,
    context = 0,
    read = 0,
    write = 0,
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

M._humanize = humanize

--- @param text string
--- @return number|nil
local function dehumanize(text)
  local num, suffix = tostring(text):match("^(%d+%.?%d*)([kM]?)$")
  local n = num and tonumber(num)
  if not n then
    return nil
  end
  if suffix == "k" then
    return math.floor(n * 1000)
  end
  if suffix == "M" then
    return math.floor(n * 1000000)
  end
  return math.floor(n)
end

M._dehumanize = dehumanize

--- The context size the most recent reported turn saw, read back out of a chat buffer.
---
--- The `### Tokens` section is the **only** place this number is kept. `_report_token_usage`
--- writes it and nothing holds on to it, so reading it back is what lets a decision about the
--- chat's size outlive both the turn that measured it and the Neovim session that ran it -- a
--- reopened chat knows how big it is without a new field in frontmatter or a second store.
---
--- Reading it back is why the section's grammar lives here next to `format`: two modules
--- disagreeing about that line is a mistake nothing would report.
---
--- Precision is the 1k the section prints, which is three orders of magnitude finer than any
--- threshold worth setting against it.
---
--- Only the last section counts. An older one describes a chat that has since grown or been
--- compacted, so an unparseable latest section reads as "unknown" rather than sending the caller
--- further back.
--- @param lines string[]
--- @return number|nil
function M.last_context(lines)
  for i = #lines, 1, -1 do
    if lines[i]:match("^###%s+Tokens%s*$") then
      for j = i + 1, math.min(i + 4, #lines) do
        local value = lines[j]:match("^context%s+(%S+)%s+·")
        if value then
          return dehumanize(value)
        end
      end
      return nil
    end
  end
  return nil
end

--- The metrics themselves, as one line, or nil when there is nothing to report.
--- @param acc Vibing.TokenUsage|nil
--- @return string|nil
function M.format(acc)
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

--- The whole `### Tokens` section for the chat buffer, or nil for a turn with nothing to report.
---
--- A section rather than a stray italic line so it sits at the same level as `### Modified Files`
--- -- the two are the same kind of thing, a per-turn footer about what the turn did, and a reader
--- scanning headings should find the cost as readily as the file list.
--- @param acc Vibing.TokenUsage|nil
--- @param warn_context number|nil
--- @return string|nil
function M.section(acc, warn_context)
  local line = M.format(acc)
  if not line then
    return nil
  end

  local warning = M.warning(acc.context, warn_context)
  return "### Tokens\n\n" .. line .. "\n" .. (warning and ("\n" .. warning .. "\n") or "")
end

return M
