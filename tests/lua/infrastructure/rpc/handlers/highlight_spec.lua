---@diagnostic disable: undefined-field
local highlight = require("vibing.infrastructure.rpc.handlers.highlight")

local function make_buffer(line_count)
  local bufnr = vim.api.nvim_create_buf(false, true)
  local lines = {}
  for i = 1, line_count do
    lines[i] = "line " .. i
  end
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  return bufnr
end

local function marks(bufnr)
  return vim.api.nvim_buf_get_extmarks(bufnr, highlight._namespace, 0, -1, { details = true })
end

describe("rpc handlers highlight", function()
  local bufnr

  before_each(function()
    bufnr = make_buffer(10)
  end)

  after_each(function()
    if vim.api.nvim_buf_is_valid(bufnr) then
      vim.api.nvim_buf_delete(bufnr, { force = true })
    end
  end)

  describe("highlight_range", function()
    it("marks the requested range with VibingHighlight", function()
      highlight.highlight_range({ bufnr = bufnr, start_line = 3, end_line = 5 })

      local found = marks(bufnr)
      assert.equals(1, #found)
      assert.equals(2, found[1][2]) -- 0-indexed start row for line 3
      assert.equals(4, found[1][4].end_row)
      assert.equals("VibingHighlight", found[1][4].hl_group)
    end)

    it("highlights a single line when end_line is omitted", function()
      highlight.highlight_range({ bufnr = bufnr, start_line = 7 })

      local found = marks(bufnr)
      assert.equals(6, found[1][2])
      assert.equals(6, found[1][4].end_row)
    end)

    it("replaces the previous highlight instead of stacking a second one", function()
      highlight.highlight_range({ bufnr = bufnr, start_line = 1, end_line = 2 })
      highlight.highlight_range({ bufnr = bufnr, start_line = 8, end_line = 9 })

      local found = marks(bufnr)
      assert.equals(1, #found)
      assert.equals(7, found[1][2])
    end)

    it("clamps a range that runs past the end of the buffer", function()
      -- Search results go stale by a line or two; pointing at roughly the right place beats
      -- refusing to point.
      local result = highlight.highlight_range({ bufnr = bufnr, start_line = 9, end_line = 999 })

      assert.equals(9, result.start_line)
      assert.equals(10, result.end_line)
      assert.equals(9, marks(bufnr)[1][4].end_row)
    end)

    it("keeps the highlight when duration_ms is 0", function()
      local result = highlight.highlight_range({ bufnr = bufnr, start_line = 1, duration_ms = 0 })

      assert.equals(0, result.duration_ms)
      assert.equals(1, #marks(bufnr))
    end)

    it("clears the highlight once duration_ms has elapsed", function()
      highlight.highlight_range({ bufnr = bufnr, start_line = 1, duration_ms = 20 })
      assert.equals(1, #marks(bufnr))

      vim.wait(300, function()
        return #marks(bufnr) == 0
      end)

      assert.equals(0, #marks(bufnr))
    end)

    it("does not let an earlier timer clear a later highlight", function()
      -- The bug this guards: without cancelling the first timer, the 20ms one fires while the
      -- second highlight is still meant to be showing.
      highlight.highlight_range({ bufnr = bufnr, start_line = 1, duration_ms = 20 })
      highlight.highlight_range({ bufnr = bufnr, start_line = 5, duration_ms = 0 })

      vim.wait(100)

      assert.equals(1, #marks(bufnr))
      assert.equals(4, marks(bufnr)[1][2])
    end)

    it("errors instead of guessing when start_line is missing", function()
      assert.has_error(function()
        highlight.highlight_range({ bufnr = bufnr })
      end)
    end)

    it("errors instead of guessing when bufnr is missing", function()
      assert.has_error(function()
        highlight.highlight_range({ start_line = 1 })
      end)
    end)

    it("errors on a buffer that does not exist", function()
      assert.has_error(function()
        highlight.highlight_range({ bufnr = 999999, start_line = 1 })
      end)
    end)
  end)

  describe("clear_highlight", function()
    it("removes a highlight that has not timed out yet", function()
      highlight.highlight_range({ bufnr = bufnr, start_line = 2, duration_ms = 0 })
      highlight.clear_highlight({ bufnr = bufnr })

      assert.equals(0, #marks(bufnr))
    end)

    it("is a no-op on a buffer with no highlight", function()
      assert.equals(true, highlight.clear_highlight({ bufnr = bufnr }).success)
    end)
  end)

  describe("VibingHighlight group", function()
    it("is defined as a default link so a user's own hi command wins", function()
      highlight.highlight_range({ bufnr = bufnr, start_line = 1 })

      local hl = vim.api.nvim_get_hl(0, { name = "VibingHighlight" })
      assert.equals("Visual", hl.link)
    end)
  end)
end)
