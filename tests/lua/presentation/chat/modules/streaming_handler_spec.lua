-- Tests for stamping the Assistant header at the end of a turn. The stamp is the only record of
-- when the prompt cache was last written, so what matters is that it lands on the turn that just
-- finished and on no other.

describe("streaming_handler.stamp_response_end", function()
  local StreamingHandler = require("vibing.presentation.chat.modules.streaming_handler")
  local Timestamp = require("vibing.core.utils.timestamp")

  local created_bufs

  before_each(function()
    created_bufs = {}
  end)

  after_each(function()
    for _, bufnr in ipairs(created_bufs) do
      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end
  end)

  --- @param lines string[]
  --- @return number bufnr
  local function scratch(lines)
    local bufnr = vim.api.nvim_create_buf(false, true)
    table.insert(created_bufs, bufnr)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    return bufnr
  end

  it("stamps the header the turn that just finished wrote", function()
    local bufnr = scratch({ "## User <!-- 2026-09-04 10:00:00 -->", "hi", "## Assistant", "an answer" })

    StreamingHandler.stamp_response_end(bufnr)

    local header = Timestamp.parse_header(vim.api.nvim_buf_get_lines(bufnr, 2, 3, false)[1])
    assert.equals("Assistant", header.kind)
    assert.is_number(Timestamp.to_epoch(header.timestamp))
  end)

  it("leaves an already-stamped header alone", function()
    local stamped = "## Assistant <!-- 2026-09-04 10:05:00 -->"
    local bufnr = scratch({ "## User <!-- 2026-09-04 10:00:00 -->", "hi", stamped, "an answer" })

    StreamingHandler.stamp_response_end(bufnr)

    assert.equals(stamped, vim.api.nvim_buf_get_lines(bufnr, 2, 3, false)[1])
  end)

  it("does not reach past a later section", function()
    -- A slash command completes through the same join point without opening an Assistant
    -- section; stamping the previous turn there would move a time that has already passed.
    local bufnr = scratch({
      "## Assistant",
      "an answer",
      "## User <!-- 2026-09-04 10:10:00 -->",
      "/save",
    })

    StreamingHandler.stamp_response_end(bufnr)

    assert.equals("## Assistant", vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1])
  end)
end)
