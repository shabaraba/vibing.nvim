--- One turn's usage on `commandcode acp`.
---
--- **The `session/prompt` reply's `usage` is a running total for the process, not for the turn.**
--- Measured on 1.88.5: three one-request turns replied 18,721 / 37,458 / 56,211 `totalTokens`
--- while each request was ~18.7k, and a process resumed with `session/load` started again from the
--- one request it had just made. Recorded as it stands, the context gauge read the sum of every
--- request since the process spawned and the `### Tokens` warning fired from the second turn on.
---
--- Two things are taken instead. The turn's own share is the difference from the totals the
--- previous reply left on the same process. The context is `usage_update.used`, which the CLI
--- reports as the window actually in use (18,725 → 18,741 → 18,757 over the same three turns, with
--- `size` the model's window); a turn with several requests would otherwise be summed into a
--- context no request ever had.
--- @module vibing.infrastructure.adapter.modules.commandcode_turn_usage

local count = require("vibing.core.utils.token_usage").count

local M = {}

local FIELDS = { "inputTokens", "cachedReadTokens", "cachedWriteTokens" }

--- What this reply adds to the totals the process had already reported.
---
--- A field that went **down** means the counter restarted, so the whole reply is this turn's: the
--- earlier totals belonged to a process that is gone, or to a session that was reloaded.
--- @param previous table|nil totals from the previous reply on this process
--- @param usage table the reply's `usage`
--- @return table delta
--- @return table totals what the next reply is compared against
function M.delta(previous, usage)
  local totals = {}
  for _, field in ipairs(FIELDS) do
    totals[field] = count(usage[field])
  end

  local restarted = previous == nil
  for _, field in ipairs(FIELDS) do
    if previous and totals[field] < previous[field] then
      restarted = true
    end
  end

  local delta = {}
  for _, field in ipairs(FIELDS) do
    delta[field] = restarted and totals[field] or totals[field] - previous[field]
  end
  return delta, totals
end

--- The turn's usage as the record `TokenUsage.record` reads.
---
--- `inputTokens` includes the cached read (`totalTokens == inputTokens + outputTokens`), so the
--- cached share is taken back out. With `used` known the three parts are fitted to it, which keeps
--- the cache split where it can be told apart and makes the context exactly what the CLI said.
--- A turn of several requests sums its cached reads past the window, so there the read figure is
--- the window, not what was billed.
--- @param previous table|nil
--- @param usage table
--- @param used any `usage_update.used` for this turn; anything but a positive number is ignored
--- @return table record
--- @return table totals
function M.turn_record(previous, usage, used)
  local delta, totals = M.delta(previous, usage)

  local read = delta.cachedReadTokens
  local write = delta.cachedWriteTokens
  local window = count(used)
  local input
  if window > 0 then
    read = math.min(read, window)
    write = math.min(write, window - read)
    input = window - read - write
  else
    input = math.max(0, delta.inputTokens - read)
  end

  return {
    input_tokens = input,
    cache_read_input_tokens = read,
    cache_creation_input_tokens = write,
  },
    totals
end

return M
