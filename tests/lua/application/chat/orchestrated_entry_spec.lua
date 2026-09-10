-- Tests for the `orchestrated` list-item codec (#696 follow-up, #717): a bare `<path>` scalar,
-- or a `{path, task}` map. The `<path>|<task>` string of PR #712 is still *read*, because chat
-- files written before #717 carry it, but it is never written again.

local OrchestratedEntry = require("vibing.application.chat.orchestrated_entry")

describe("OrchestratedEntry", function()
  describe("encode", function()
    it("returns the bare path when task is nil", function()
      assert.equals(".vibing/chat/worker.md", OrchestratedEntry.encode(".vibing/chat/worker.md", nil))
    end)

    it("returns the bare path when task is the empty string", function()
      assert.equals(".vibing/chat/worker.md", OrchestratedEntry.encode(".vibing/chat/worker.md", ""))
    end)

    it("returns a map when there is a task", function()
      assert.same(
        { path = ".vibing/chat/worker.md", task = "PR #688 -- review fixes, merge" },
        OrchestratedEntry.encode(".vibing/chat/worker.md", "PR #688 -- review fixes, merge")
      )
    end)

    it("never writes the legacy pipe form", function()
      local encoded = OrchestratedEntry.encode(".vibing/chat/worker.md", "merge")

      assert.is_table(encoded)
      assert.is_nil(tostring(encoded.path):find("|", 1, true))
    end)
  end)

  describe("decode", function()
    it("returns the whole string as path, and nil task, for a bare scalar", function()
      local path, task = OrchestratedEntry.decode(".vibing/chat/worker.md")

      assert.equals(".vibing/chat/worker.md", path)
      assert.is_nil(task)
    end)

    it("reads a map element", function()
      local path, task = OrchestratedEntry.decode({ path = ".vibing/chat/worker.md", task = "PR #688 -- merge" })

      assert.equals(".vibing/chat/worker.md", path)
      assert.equals("PR #688 -- merge", task)
    end)

    it("reads a map element with no task", function()
      local path, task = OrchestratedEntry.decode({ path = ".vibing/chat/worker.md" })

      assert.equals(".vibing/chat/worker.md", path)
      assert.is_nil(task)
    end)

    it("still splits the legacy pipe form written before #717", function()
      local path, task = OrchestratedEntry.decode(".vibing/chat/worker.md|PR #688 -- review, merge")

      assert.equals(".vibing/chat/worker.md", path)
      assert.equals("PR #688 -- review, merge", task)
    end)

    it("returns nil for an element it cannot read", function()
      -- Frontmatter is hand-editable, so a malformed element has to be skippable rather than
      -- fatal at every call site.
      assert.is_nil((OrchestratedEntry.decode({ task = "orphaned" })))
      assert.is_nil((OrchestratedEntry.decode("")))
      assert.is_nil((OrchestratedEntry.decode(42)))
    end)

    it("round-trips through encode", function()
      local encoded = OrchestratedEntry.encode(".vibing/chat/worker.md", "Issue #696 -- task frontmatter")
      local path, task = OrchestratedEntry.decode(encoded)

      assert.equals(".vibing/chat/worker.md", path)
      assert.equals("Issue #696 -- task frontmatter", task)
    end)
  end)

  describe("find", function()
    it("returns nil when no entry matches the path", function()
      local entry, task = OrchestratedEntry.find({ { path = "a.md", task = "task a" }, "b.md" }, "c.md")

      assert.is_nil(entry)
      assert.is_nil(task)
    end)

    it("finds a task-bearing entry by its path", function()
      local entries = { { path = "a.md", task = "task a" }, "b.md" }

      local entry, task = OrchestratedEntry.find(entries, "a.md")

      assert.same({ path = "a.md", task = "task a" }, entry)
      assert.equals("task a", task)
    end)

    it("finds a bare-path entry with a nil task", function()
      local entries = { { path = "a.md", task = "task a" }, "b.md" }

      local entry, task = OrchestratedEntry.find(entries, "b.md")

      assert.equals("b.md", entry)
      assert.is_nil(task)
    end)

    it("finds an entry still written in the legacy pipe form", function()
      local entry, task = OrchestratedEntry.find({ "a.md|task a", "b.md" }, "a.md")

      assert.equals("a.md|task a", entry)
      assert.equals("task a", task)
    end)
  end)

  describe("paths", function()
    it("takes the path out of every readable element and drops the rest", function()
      local paths = OrchestratedEntry.paths({
        "a.md",
        { path = "b.md", task = "task b" },
        "c.md|task c",
        { task = "orphaned" },
      })

      assert.same({ "a.md", "b.md", "c.md" }, paths)
    end)
  end)
end)
