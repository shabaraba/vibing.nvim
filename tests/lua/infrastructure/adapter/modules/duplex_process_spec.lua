-- Line framing on a resident process. `on_stdout` hands over arbitrary byte batches, so a single
-- stream-json line routinely arrives split across several of them and the partial has to be carried
-- forward. The thing this has to survive is a dispatch that raises: `on_line` runs the whole decoder
-- and renderer, and the raise comes straight back out here.
local DuplexProcess = require("vibing.infrastructure.adapter.modules.duplex_process")

describe("duplex_process line framing", function()
  --- @return table record, string[] seen
  local function make_record()
    local seen = {}
    return {
      _pending = { "" },
      on_line = function(line)
        table.insert(seen, line)
      end,
    }, seen
  end

  it("joins a line split across batches", function()
    local record, seen = make_record()

    DuplexProcess._absorb(record, { '{"a":' })
    DuplexProcess._absorb(record, { '1}', '{"b":2}', '{"c":' })
    DuplexProcess._absorb(record, { '3}', "" })

    assert.same({ '{"a":1}', '{"b":2}', '{"c":3}' }, seen)
  end)

  it("carries the partial forward even when dispatching a line raises", function()
    -- The wedge this exists to stop: with the reset left until after the dispatch loop, a decoder
    -- that raised on the first line left the *previous* fragments in place. Every later line was
    -- then concatenated onto them, stopped parsing as JSON, and the process could never report the
    -- end of another turn -- the chat sat at `responding` with a live CLI that had already answered.
    local record, seen = make_record()
    record.on_line = function(line)
      table.insert(seen, line)
      error("decoder blew up")
    end

    assert.has_error(function()
      DuplexProcess._absorb(record, { '{"a":1}', '{"b":2}', '{"c":' })
    end)
    assert.same({ '{"a":1}' }, seen)
    assert.same({ '{"c":' }, record._pending)

    record.on_line = function(line)
      table.insert(seen, line)
    end
    DuplexProcess._absorb(record, { '2}', "" })
    assert.same({ '{"a":1}', '{"c":2}' }, seen)
  end)
end)
