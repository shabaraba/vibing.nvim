-- Extracted out of infrastructure/rpc/handlers/buffer.lua so `nvim_get_buffer` and the
-- orchestration "stopped without report" notification (completion_notifier.lua, #693) read a
-- live buffer's last section the same way. `buffer_spec.lua` already pins the chunked
-- backward-scan behaviour through `buf_get_lines`; this only pins the shared entry point itself.
local BufferTail = require("vibing.application.chat.buffer_tail")

describe("BufferTail.read_last_section", function()
  local buffers = {}

  local function make_buffer(lines)
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    table.insert(buffers, bufnr)
    return bufnr
  end

  after_each(function()
    for _, bufnr in ipairs(buffers) do
      if vim.api.nvim_buf_is_valid(bufnr) then
        vim.api.nvim_buf_delete(bufnr, { force = true })
      end
    end
    buffers = {}
  end)

  it("windows to the last '## ...' section and reports the real total", function()
    local target = make_buffer({
      "## User <!-- 2026-01-01 00:00:00 -->",
      "first",
      "## Assistant <!-- 2026-01-01 00:00:01 -->",
      "second",
    })

    local windowed, total_lines = BufferTail.read_last_section(target)

    assert.same({ "## Assistant <!-- 2026-01-01 00:00:01 -->", "second" }, windowed)
    assert.equals(4, total_lines)
  end)

  it("combines the last section with a tail_lines cap", function()
    local target = make_buffer({
      "## Assistant <!-- 2026-01-01 00:00:00 -->",
      "one",
      "two",
      "three",
    })

    local windowed = BufferTail.read_last_section(target, 2)

    assert.same({ "two", "three" }, windowed)
  end)

  it("finds a header beyond the first backward-scan chunk by doubling", function()
    local lines = {}
    for i = 1, 599 do
      lines[i] = "filler " .. i
    end
    lines[600] = "## Assistant <!-- 2026-01-01 00:00:00 -->"
    for i = 601, 1200 do
      lines[i] = "reply " .. i
    end
    local target = make_buffer(lines)

    local windowed, total_lines = BufferTail.read_last_section(target)

    assert.equals(1200, total_lines)
    assert.equals("## Assistant <!-- 2026-01-01 00:00:00 -->", windowed[1])
    assert.equals("reply 1200", windowed[#windowed])
  end)
end)
