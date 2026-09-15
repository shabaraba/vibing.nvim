--- Builds the `processLine` a backend hands to `stream_handler` from its decoder.
---
--- A decoder is `{ decode = fun(msg: table, state: table): Vibing.CanonicalEvent[] }`: a pure
--- translation from one line of the CLI's JSON into canonical events, keeping whatever it needs
--- to remember across lines in `state`. Everything after that -- rendering, callbacks, session
--- storage -- is `event_renderer.lua`, shared by every backend.
--- @module vibing.infrastructure.adapter.modules.stream_decoder

local Renderer = require("vibing.infrastructure.adapter.modules.event_renderer")

local M = {}

--- @param decoder { decode: fun(msg: table, state: table): Vibing.CanonicalEvent[] }
--- @param vocabulary table? the backend's tool vocabulary, so names are canonicalised the same
---   way the permission handler canonicalises them
--- @return { processLine: fun(line: string, context: table): boolean, decoder: table }
function M.processor(decoder, vocabulary)
  assert(type(decoder) == "table" and type(decoder.decode) == "function", "decoder needs decode()")

  local processor = { decoder = decoder, vocabulary = vocabulary }

  --- Process one JSON line from the CLI's stdout.
  --- @param line string
  --- @param context table
  --- @return boolean processed false for an empty or unparsable line
  function processor.processLine(line, context)
    if line == "" or not context then
      return false
    end

    local ok, msg = pcall(vim.json.decode, line)
    if not ok or type(msg) ~= "table" or not msg.type then
      return false
    end

    if context.vocabulary == nil then
      context.vocabulary = vocabulary
    end
    context._decoder_state = context._decoder_state or {}

    local events = decoder.decode(msg, context._decoder_state)
    for _, event in ipairs(events or {}) do
      Renderer.handle(event, context)
    end
    return true
  end

  return processor
end

return M
