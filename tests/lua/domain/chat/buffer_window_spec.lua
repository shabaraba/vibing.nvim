local BufferWindow = require("vibing.domain.chat.buffer_window")

describe("BufferWindow.slice", function()
  it("returns everything unchanged and the matching total when no option is given", function()
    local lines = { "a", "b", "c" }

    local windowed, total_lines = BufferWindow.slice(lines, nil)

    assert.same({ "a", "b", "c" }, windowed)
    assert.equals(3, total_lines)
  end)

  it("keeps only the last N lines with tail_lines", function()
    local lines = { "a", "b", "c", "d", "e" }

    local windowed, total_lines = BufferWindow.slice(lines, { tail_lines = 2 })

    assert.same({ "d", "e" }, windowed)
    assert.equals(5, total_lines)
  end)

  it("leaves a buffer shorter than tail_lines untouched", function()
    local lines = { "a", "b" }

    local windowed, total_lines = BufferWindow.slice(lines, { tail_lines = 40 })

    assert.same({ "a", "b" }, windowed)
    assert.equals(2, total_lines)
  end)

  it("cuts at the last '## ...' section boundary with last_section", function()
    local lines = { "## User <!-- 2026-01-01 00:00:00 -->", "first", "## Assistant <!-- 2026-01-01 00:00:01 -->", "second", "reply" }

    local windowed, total_lines = BufferWindow.slice(lines, { last_section = true })

    assert.same({ "## Assistant <!-- 2026-01-01 00:00:01 -->", "second", "reply" }, windowed)
    assert.equals(5, total_lines)
  end)

  it("returns the whole buffer for last_section when there is no header at all", function()
    local lines = { "plain", "text", "no headers here" }

    local windowed, total_lines = BufferWindow.slice(lines, { last_section = true })

    assert.same({ "plain", "text", "no headers here" }, windowed)
    assert.equals(3, total_lines)
  end)

  it("recognizes legacy headers with no timestamp comment", function()
    local lines = { "## User", "first", "## Assistant", "second" }

    local windowed = BufferWindow.slice(lines, { last_section = true })

    assert.same({ "## Assistant", "second" }, windowed)
  end)

  it("applies tail_lines on top of last_section, not on the whole buffer", function()
    local lines = {
      "## User <!-- 2026-01-01 00:00:00 -->",
      "one",
      "two",
      "## Assistant <!-- 2026-01-01 00:00:01 -->",
      "three",
      "four",
      "five",
    }

    local windowed, total_lines = BufferWindow.slice(lines, { last_section = true, tail_lines = 2 })

    assert.same({ "four", "five" }, windowed)
    assert.equals(7, total_lines)
  end)

  it("treats tail_lines = 0 as an empty window", function()
    local windowed = BufferWindow.slice({ "a", "b" }, { tail_lines = 0 })

    assert.same({}, windowed)
  end)

  it("does not mutate the input", function()
    local lines = { "a", "b", "c" }

    BufferWindow.slice(lines, { tail_lines = 1 })

    assert.same({ "a", "b", "c" }, lines)
  end)

  describe("normalize_tail_lines (a defensive-coding review finding on PR #707)", function()
    it("clamps a negative tail_lines to zero rather than ignoring it", function()
      -- Unreachable through the MCP layer (validated non-negative there), but this primitive is
      -- meant to be called directly by a future Lua caller (#693) that skips that validation.
      assert.same({}, BufferWindow.slice({ "a", "b" }, { tail_lines = -1 }))
    end)

    it("clamps a negative tail_lines the same way whether or not last_section is also given", function()
      local lines = { "## User <!-- 2026-01-01 00:00:00 -->", "one", "two" }

      assert.same({}, BufferWindow.slice(lines, { tail_lines = -1, last_section = true }))
    end)

    it("floors a fractional tail_lines instead of producing a fractional slice bound", function()
      local windowed = BufferWindow.slice({ "a", "b", "c" }, { tail_lines = 1.9 })

      assert.same({ "c" }, windowed)
    end)

    it("treats a non-number tail_lines as not given", function()
      assert.equals(nil, BufferWindow.normalize_tail_lines("3"))
      assert.equals(nil, BufferWindow.normalize_tail_lines(nil))
    end)
  end)
end)
