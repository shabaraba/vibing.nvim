--- Builds the `processLine` a backend hands to `stream_handler` from its decoder.
---
--- A decoder is `{ decode = fun(msg: table, state: table): Vibing.CanonicalEvent[] }`: a pure
--- translation from one line of the CLI's JSON into canonical events, keeping whatever it needs
--- to remember across lines in `state`. Everything after that -- rendering, callbacks, session
--- storage -- is `event_renderer.lua`, shared by every backend.
--- @module vibing.infrastructure.adapter.modules.stream_decoder

local Renderer = require("vibing.infrastructure.adapter.modules.event_renderer")

local M = {}

--- Decode one line and hand its events to the renderer.
---
--- A named function rather than a closure inside `processLine` so the `pcall` below costs no
--- allocation per line: with `--include-partial-messages` there is one line per token.
--- @param decoder table
--- @param msg table
--- @param context table
local function apply(decoder, msg, context)
  for _, event in ipairs(decoder.decode(msg, context._decoder_state) or {}) do
    Renderer.handle(event, context)
  end
end

--- @param decoder { decode: fun(msg: table, state: table): Vibing.CanonicalEvent[] }
--- @param vocabulary table? the backend's tool vocabulary, so names are canonicalised the same
---   way the permission handler canonicalises them
--- @return { processLine: fun(line: string, context: table): boolean, decoder: table }
function M.processor(decoder, vocabulary)
  assert(type(decoder) == "table" and type(decoder.decode) == "function", "decoder needs decode()")

  local processor = { decoder = decoder, vocabulary = vocabulary }

  --- Decode one already-in-memory message and hand its events to the renderer.
  ---
  --- The entry point for a caller that built the message itself rather than reading it off a
  --- wire -- a resident JSON-RPC transport's own notifications and locally-built notices, which
  --- otherwise had no way to reach the renderer except encoding back to JSON only for
  --- `processLine` to immediately decode it again.
  --- @param msg table
  --- @param context table
  --- @return boolean processed
  function processor.apply(msg, context)
    if not context then
      return false
    end

    if context.vocabulary == nil then
      context.vocabulary = vocabulary
    end
    context._decoder_state = context._decoder_state or {}

    -- **A message the decoder cannot handle costs that message, and nothing else.** Letting the
    -- raise out takes the caller with it, and the caller is a stdout callback: on the resident
    -- transport the rest of that batch is dropped -- the `result` that ends the turn is routinely
    -- in it -- and the chat then sits at `responding` with no process left to end it. Reported
    -- once per stream, because the shape that fails once usually fails on every line that carries
    -- it.
    local ok, err = pcall(apply, decoder, msg, context)
    if not ok then
      if not context._decode_failed then
        context._decode_failed = true
        require("vibing.core.utils.notify").error(
          string.format("Could not decode a '%s' line from the CLI: %s", tostring(msg.type or msg.method), tostring(err))
        )
      end
      return false
    end
    return true
  end

  --- Process one JSON line from the CLI's stdout.
  --- @param line string
  --- @param context table
  --- @return boolean processed false for an empty or unparsable line
  function processor.processLine(line, context)
    if line == "" or not context then
      return false
    end

    -- `type` and nothing else: every caller of this entry point reads stream-json off a stdout
    -- pipe. A resident JSON-RPC transport's `method`-keyed messages reach the renderer through
    -- `apply`, never through here, so widening the gate to accept them would only let a malformed
    -- stream-json line past the one check that rejects it.
    local ok, msg = pcall(vim.json.decode, line)
    if not ok or type(msg) ~= "table" or not msg.type then
      return false
    end

    return processor.apply(msg, context)
  end

  return processor
end

return M
