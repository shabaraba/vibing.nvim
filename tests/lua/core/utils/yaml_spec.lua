-- Tests for vibing.core.utils.yaml (#717)
--
-- The subset this has to get right is exactly what a chat frontmatter contains: scalars, flat
-- lists, and lists whose elements are maps. Everything else is allowed to degrade, and a few
-- tests below pin the degradation so it stays a choice rather than a surprise.

local Yaml = require("vibing.core.utils.yaml")

describe("yaml.decode", function()
  it("reads scalars with their types", function()
    local data = Yaml.decode({
      "vibing.nvim: true",
      "enabled: false",
      "count: 42",
      "model: sonnet",
    })

    assert.equals(true, data["vibing.nvim"])
    assert.equals(false, data.enabled)
    assert.equals(42, data.count)
    assert.equals("sonnet", data.model)
  end)

  it("keeps a timestamp with colons in it as one string", function()
    assert.equals("2024-01-01T12:00:00", Yaml.decode({ "created_at: 2024-01-01T12:00:00" }).created_at)
  end)

  it("leaves ~ alone instead of reading it as null", function()
    -- A chat template writes `session_id: ~` to mean "no session yet", and the readers of that
    -- field expect a string.
    assert.equals("~", Yaml.decode({ "session_id: ~" }).session_id)
  end)

  it("reads a flat block list", function()
    assert.same({ "Read", "Edit" }, Yaml.decode({ "permissions_allow:", "  - Read", "  - Edit" }).permissions_allow)
  end)

  it("reads a valueless key and [] alike as an empty list", function()
    local data = Yaml.decode({ "orchestrated:", "permissions_deny: []" })

    assert.same({}, data.orchestrated)
    assert.same({}, data.permissions_deny)
  end)

  it("reads a list of maps", function()
    local data = Yaml.decode({
      "orchestrated:",
      "  - path: chat/a.md",
      "    task: first",
      "  - path: chat/b.md",
      "    task: second",
    })

    assert.same({
      { path = "chat/a.md", task = "first" },
      { path = "chat/b.md", task = "second" },
    }, data.orchestrated)
  end)

  it("reads a list that mixes scalars and maps", function()
    local data = Yaml.decode({
      "orchestrated:",
      "  - chat/idle.md",
      "  - path: chat/b.md",
      "    task: second",
    })

    assert.same({ "chat/idle.md", { path = "chat/b.md", task = "second" } }, data.orchestrated)
  end)

  it("ends a nested block at the next top-level key", function()
    local data = Yaml.decode({
      "orchestrated:",
      "  - path: chat/a.md",
      "    task: first",
      "model: opus",
      "language: ja",
    })

    assert.same({ { path = "chat/a.md", task = "first" } }, data.orchestrated)
    assert.equals("opus", data.model)
    assert.equals("ja", data.language)
  end)

  it("reads a nested map", function()
    local data = Yaml.decode({ "window:", "  position: right", "  width: 80" })

    assert.same({ position = "right", width = 80 }, data.window)
  end)

  it("unquotes a value that had to be quoted", function()
    local data = Yaml.decode({ 'task: "PR #688 -- merge"', "note: 'it''s fine'" })

    assert.equals("PR #688 -- merge", data.task)
    assert.equals("it's fine", data.note)
  end)

  it("skips blank lines and comments", function()
    local data = Yaml.decode({ "# a note", "", "model: opus", "  ", "language: ja" })

    assert.equals("opus", data.model)
    assert.equals("ja", data.language)
  end)

  it("drops a line it cannot read instead of losing the rest", function()
    -- Frontmatter is hand-editable, so one botched line must not cost the whole block.
    local data = Yaml.decode({ "model: opus", "this line is not yaml", "language: ja" })

    assert.equals("opus", data.model)
    assert.equals("ja", data.language)
  end)

  it("absorbs the trailing CR of a CRLF file", function()
    local data = Yaml.decode("model: opus\r\npermissions_allow:\r\n  - Read\r")

    assert.equals("opus", data.model)
    assert.same({ "Read" }, data.permissions_allow)
  end)

  it("returns an empty table for an empty block", function()
    assert.same({}, Yaml.decode({}))
    assert.same({}, Yaml.decode(""))
  end)
end)

describe("yaml.encode", function()
  it("orders keys by the given order, then alphabetically", function()
    local lines = Yaml.encode({ language = "ja", session_id = "abc", zebra = 1, alpha = 2 }, { "session_id", "language" })

    assert.same({ "session_id: abc", "language: ja", "alpha: 2", "zebra: 1" }, lines)
  end)

  it("writes a flat list", function()
    assert.same({ "permissions_allow:", "  - Read", "  - Edit" }, Yaml.encode({ permissions_allow = { "Read", "Edit" } }))
  end)

  it("writes an empty list as a bare key", function()
    assert.same({ "orchestrated:" }, Yaml.encode({ orchestrated = {} }))
  end)

  it("writes a list of maps", function()
    local lines = Yaml.encode({ orchestrated = { { path = "chat/a.md", task = "first" }, "chat/b.md" } })

    assert.same({ "orchestrated:", "  - path: chat/a.md", "    task: first", "  - chat/b.md" }, lines)
  end)

  it("quotes a value that would otherwise change meaning", function()
    local lines = Yaml.encode({
      comment = "PR #688 -- merge",
      mapping = "key: value",
      trailing = "spaced ",
      dashed = "-leading",
      numeric = "42",
      boolish = "true",
      empty = "",
    })

    assert.same({
      'boolish: "true"',
      'comment: "PR #688 -- merge"',
      'dashed: "-leading"',
      'empty: ""',
      'mapping: "key: value"',
      'numeric: "42"',
      'trailing: "spaced "',
    }, lines)
  end)

  it("leaves an ordinary path or timestamp unquoted", function()
    local lines = Yaml.encode({
      created_at = "2024-01-01T12:00:00",
      home = "~/proj/chat/a.md",
      rel = ".vibing/chat/a.md",
      session_id = "~",
    })

    assert.same({
      "created_at: 2024-01-01T12:00:00",
      "home: ~/proj/chat/a.md",
      "rel: .vibing/chat/a.md",
      "session_id: ~",
    }, lines)
  end)
end)

describe("yaml round trip", function()
  it("returns the same table it was given", function()
    local original = {
      ["vibing.nvim"] = true,
      session_id = "abc-123",
      permissions_allow = { "Read", "Edit" },
      permissions_deny = {},
      orchestrated = {
        "chat/idle.md",
        { path = "chat/worker.md", task = 'PR #688: "review", then merge' },
      },
      window = { position = "right", width = 80 },
    }

    assert.same(original, Yaml.decode(Yaml.encode(original)))
  end)
end)
