---@diagnostic disable: undefined-field
local annotations = require("vibing.infrastructure.rpc.handlers.annotations")

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
  return vim.api.nvim_buf_get_extmarks(bufnr, annotations._namespace, 0, -1, { details = true })
end

describe("rpc handlers annotations", function()
  local bufnr

  before_each(function()
    bufnr = make_buffer(10)
  end)

  after_each(function()
    annotations.clear_annotations({})
    if vim.api.nvim_buf_is_valid(bufnr) then
      vim.api.nvim_buf_delete(bufnr, { force = true })
    end
  end)

  describe("annotate", function()
    it("puts the note under the requested line as virtual lines", function()
      annotations.annotate({ bufnr = bufnr, line = 4, text = "this leaks a handle" })

      local found = marks(bufnr)
      assert.equals(1, #found)
      assert.equals(3, found[1][2]) -- 0-indexed row for line 4
      assert.equals(1, #found[1][4].virt_lines)
      assert.equals("┃ this leaks a handle", found[1][4].virt_lines[1][1][1])
    end)

    it("never marks the buffer modified, since the file is untouched", function()
      annotations.annotate({ bufnr = bufnr, line = 1, text = "note" })

      assert.is_false(vim.bo[bufnr].modified)
    end)

    it("splits a multi-line note into one virtual line each", function()
      annotations.annotate({ bufnr = bufnr, line = 2, text = "first\nsecond\nthird" })

      local virt_lines = marks(bufnr)[1][4].virt_lines
      assert.equals(3, #virt_lines)
      assert.equals("┃ second", virt_lines[2][1][1])
    end)

    it("colours the note by severity", function()
      annotations.annotate({ bufnr = bufnr, line = 1, text = "a", severity = "warn" })
      assert.equals("VibingAnnotationWarn", marks(bufnr)[1][4].virt_lines[1][1][2])

      annotations.clear_annotations({ bufnr = bufnr })
      annotations.annotate({ bufnr = bufnr, line = 1, text = "a", severity = "error" })
      assert.equals("VibingAnnotationError", marks(bufnr)[1][4].virt_lines[1][1][2])
    end)

    it("falls back to info for an unknown severity", function()
      local result = annotations.annotate({ bufnr = bufnr, line = 1, text = "a", severity = "nope" })

      assert.equals("info", result.severity)
      assert.equals("VibingAnnotationInfo", marks(bufnr)[1][4].virt_lines[1][1][2])
    end)

    it("keeps several notes on the same buffer, unlike highlights", function()
      annotations.annotate({ bufnr = bufnr, line = 1, text = "one" })
      annotations.annotate({ bufnr = bufnr, line = 5, text = "two" })

      assert.equals(2, #marks(bufnr))
    end)

    it("clamps a line past the end of the buffer", function()
      local result = annotations.annotate({ bufnr = bufnr, line = 999, text = "a" })

      assert.equals(10, result.line)
    end)

    it("returns the extmark id", function()
      local result = annotations.annotate({ bufnr = bufnr, line = 1, text = "a" })

      assert.is_number(result.extmark_id)
    end)

    it("errors when line or text is missing", function()
      assert.has_error(function()
        annotations.annotate({ bufnr = bufnr, text = "a" })
      end)
      assert.has_error(function()
        annotations.annotate({ bufnr = bufnr, line = 1 })
      end)
      assert.has_error(function()
        annotations.annotate({ bufnr = bufnr, line = 1, text = "" })
      end)
    end)
  end)

  describe("clear_annotations", function()
    it("clears the named buffer", function()
      annotations.annotate({ bufnr = bufnr, line = 1, text = "a" })
      local result = annotations.clear_annotations({ bufnr = bufnr })

      assert.equals(0, #marks(bufnr))
      assert.same({ bufnr }, result.cleared_buffers)
    end)

    it("clears every buffer when bufnr is omitted", function()
      local other = make_buffer(3)
      annotations.annotate({ bufnr = bufnr, line = 1, text = "a" })
      annotations.annotate({ bufnr = other, line = 1, text = "b" })

      local result = annotations.clear_annotations({})

      assert.equals(0, #marks(bufnr))
      assert.equals(0, #marks(other))
      assert.equals(2, #result.cleared_buffers)

      vim.api.nvim_buf_delete(other, { force = true })
    end)

    it("reports no buffers when there was nothing to clear", function()
      assert.same({}, annotations.clear_annotations({}).cleared_buffers)
    end)
  end)

  describe("highlight groups", function()
    it("defines the three severity groups as default links", function()
      annotations.annotate({ bufnr = bufnr, line = 1, text = "a" })

      assert.equals("DiagnosticVirtualTextInfo", vim.api.nvim_get_hl(0, { name = "VibingAnnotationInfo" }).link)
      assert.equals("DiagnosticVirtualTextWarn", vim.api.nvim_get_hl(0, { name = "VibingAnnotationWarn" }).link)
      assert.equals("DiagnosticVirtualTextError", vim.api.nvim_get_hl(0, { name = "VibingAnnotationError" }).link)
    end)
  end)
end)
