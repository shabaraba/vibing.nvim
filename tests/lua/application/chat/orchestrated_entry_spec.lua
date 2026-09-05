-- Tests for the `orchestrated` list-item codec (#696 follow-up): `<path>` or `<path>|<task>`.

local OrchestratedEntry = require("vibing.application.chat.orchestrated_entry")

describe("OrchestratedEntry", function()
  describe("encode", function()
    it("returns the bare path when task is nil", function()
      assert.equals(".vibing/chat/worker.md", OrchestratedEntry.encode(".vibing/chat/worker.md", nil))
    end)

    it("returns the bare path when task is the empty string", function()
      assert.equals(".vibing/chat/worker.md", OrchestratedEntry.encode(".vibing/chat/worker.md", ""))
    end)

    it("joins path and task with a pipe", function()
      assert.equals(
        ".vibing/chat/worker.md|PR #688 -- review fixes, merge",
        OrchestratedEntry.encode(".vibing/chat/worker.md", "PR #688 -- review fixes, merge")
      )
    end)
  end)

  describe("decode", function()
    it("returns the whole string as path, and nil task, when there is no pipe", function()
      local path, task = OrchestratedEntry.decode(".vibing/chat/worker.md")

      assert.equals(".vibing/chat/worker.md", path)
      assert.is_nil(task)
    end)

    it("splits at the first pipe", function()
      local path, task = OrchestratedEntry.decode(".vibing/chat/worker.md|PR #688 -- review, merge")

      assert.equals(".vibing/chat/worker.md", path)
      assert.equals("PR #688 -- review, merge", task)
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
      local entry, task = OrchestratedEntry.find({ "a.md|task a", "b.md" }, "c.md")

      assert.is_nil(entry)
      assert.is_nil(task)
    end)

    it("finds a task-bearing entry by its path", function()
      local entries = { "a.md|task a", "b.md" }

      local entry, task = OrchestratedEntry.find(entries, "a.md")

      assert.equals("a.md|task a", entry)
      assert.equals("task a", task)
    end)

    it("finds a bare-path entry with a nil task", function()
      local entries = { "a.md|task a", "b.md" }

      local entry, task = OrchestratedEntry.find(entries, "b.md")

      assert.equals("b.md", entry)
      assert.is_nil(task)
    end)
  end)
end)
