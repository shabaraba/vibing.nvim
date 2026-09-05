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
end)
