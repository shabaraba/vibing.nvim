describe("prefix_rewrite", function()
  local PrefixRewrite = require("vibing.core.utils.prefix_rewrite")
  local TokenUsage = require("vibing.core.utils.token_usage")

  local BASE = 1770000000

  --- A user directory with nothing in it, so these cases cannot be swayed by whenever the
  --- developer running them last edited their own `~/.claude/rules`.
  local NO_HOME = "/nonexistent-home-for-prefix-rewrite-spec"

  local function facts(overrides)
    return vim.tbl_extend("force", {
      at = BASE,
      model = "claude-opus-5",
      effort = "high",
      version = "2.1.231",
      compacted = false,
    }, overrides or {})
  end

  --- A turn whose opening request had this prompt size and this much of it written.
  local function acc_of(context, write)
    local acc = TokenUsage.new()
    acc.requests = 3
    acc.context = context
    acc.read = context * 2
    acc.write = write
    acc.first_context = context
    acc.first_write = write
    return acc
  end

  describe("detect", function()
    it("flags a turn that re-wrote most of its context", function()
      local found = PrefixRewrite.detect(acc_of(200000, 198000), facts(), facts({ at = BASE + 60 }), nil, NO_HOME)

      assert.truthy(found)
      assert.equals(198000, found.write)
    end)

    it("says nothing about a turn that only appended to a warm prefix", function()
      -- The ordinary shape: a large context, a small delta. Flagging this would make the note
      -- appear on every turn and stop meaning anything.
      assert.is_nil(PrefixRewrite.detect(acc_of(200000, 12000), facts(), facts({ at = BASE + 60 }), nil, NO_HOME))
    end)

    it("says nothing without a previous turn to compare against", function()
      -- A session's first turn writes its whole prefix by definition -- that is the cache being
      -- filled, not missed. Reporting it would make the loudest line the least actionable one.
      assert.is_nil(PrefixRewrite.detect(acc_of(110000, 110000), nil, facts(), nil, NO_HOME))
    end)

    it("says nothing when the turn reported no context", function()
      assert.is_nil(PrefixRewrite.detect(acc_of(0, 0), facts(), facts({ at = BASE + 60 }), nil, NO_HOME))
    end)

    it("is not fooled by a long turn's accumulated writes", function()
      -- Every request after the opening one writes its own increment, so a turn with enough tool
      -- calls sums to more `write` than its `context` while hitting the cache on all of them.
      -- Measured on a real turn here: context 99k, 9 requests, write 146k.
      local acc = TokenUsage.new()
      acc.requests = 9
      acc.context = 99000
      acc.read = 644000
      acc.write = 146000
      acc.first_context = 99000
      acc.first_write = 1200

      assert.is_nil(PrefixRewrite.detect(acc, facts(), facts({ at = BASE + 60 }), nil, NO_HOME))
    end)

    it("reports the opening request's write, not the turn's total", function()
      local acc = TokenUsage.new()
      acc.requests = 9
      acc.context = 200000
      acc.read = 300000
      acc.write = 260000
      acc.first_context = 200000
      acc.first_write = 198000

      -- The prefix that had to be rebuilt is the opening request's, and that is the number a
      -- reader can act on; the sum includes increments no cache could have saved.
      assert.equals(198000, PrefixRewrite.detect(acc, facts(), facts({ at = BASE + 60 }), nil, NO_HOME).write)
    end)

    it("survives a usage accumulator of an unexpected shape", function()
      assert.is_nil(PrefixRewrite.detect(nil, facts(), facts(), nil))
      assert.is_nil(PrefixRewrite.detect("not a table", facts(), facts(), nil))
    end)
  end)

  describe("causes", function()
    it("names an expired cache TTL with the gap that caused it", function()
      local causes = PrefixRewrite.causes(facts(), facts({ at = BASE + 4320 }), {})

      assert.equals(1, #causes)
      assert.truthy(causes[1]:find("1h12m", 1, true))
      assert.truthy(causes[1]:find("TTL", 1, true))
    end)

    it("leaves the TTL out for a gap inside the window", function()
      assert.same({}, PrefixRewrite.causes(facts(), facts({ at = BASE + 3599 }), {}))
    end)

    it("measures the gap to the turn's start when the CLI reported one", function()
      -- `at` is when a turn *ended*, so a turn that spent an hour in tool calls looks an hour
      -- further from the previous one than the cache ever sat idle.
      local long_turn = facts({ at = BASE + 7200, started_at = BASE + 1800 })

      assert.same({}, PrefixRewrite.causes(facts(), long_turn, {}))
    end)

    it("falls back to the end time when it was never told the start", function()
      local causes = PrefixRewrite.causes(facts(), facts({ at = BASE + 7200, started_at = nil }), {})

      assert.equals(1, #causes)
      assert.truthy(causes[1]:find("TTL", 1, true))
    end)

    it("names a model change with both values", function()
      local causes = PrefixRewrite.causes(facts(), facts({ at = BASE + 60, model = "claude-sonnet-5" }), {})

      assert.equals(1, #causes)
      assert.truthy(causes[1]:find("claude-opus-5 to claude-sonnet-5", 1, true))
    end)

    it("names an effort change", function()
      local causes = PrefixRewrite.causes(facts(), facts({ at = BASE + 60, effort = "low" }), {})

      assert.equals(1, #causes)
      assert.truthy(causes[1]:find("effort changed (high to low)", 1, true))
    end)

    it("names the edited prompt sources", function()
      local causes = PrefixRewrite.causes(facts(), facts({ at = BASE + 60 }), { "CLAUDE.md", ".claude/rules/architecture.md" })

      assert.equals(1, #causes)
      assert.truthy(causes[1]:find("CLAUDE.md, .claude/rules/architecture.md edited since the last turn", 1, true))
    end)

    it("summarises a large edit instead of listing every file", function()
      local causes = PrefixRewrite.causes(facts(), facts({ at = BASE + 60 }), { "a.md", "b.md", "c.md", "d.md", "e.md" })

      assert.truthy(causes[1]:find("a.md, b.md, c.md and 2 more", 1, true))
    end)

    it("names a compaction that happened on the previous turn", function()
      local causes = PrefixRewrite.causes(facts({ compacted = true }), facts({ at = BASE + 60 }), {})

      assert.equals(1, #causes)
      assert.truthy(causes[1]:find("compacted", 1, true))
    end)

    it("names a Claude Code upgrade", function()
      local causes = PrefixRewrite.causes(facts(), facts({ at = BASE + 60, version = "2.1.232" }), {})

      assert.equals(1, #causes)
      assert.truthy(causes[1]:find("2.1.231 to 2.1.232", 1, true))
    end)

    it("lists every cause that applies, in the order they were catalogued", function()
      local causes = PrefixRewrite.causes(
        facts({ compacted = true }),
        facts({ at = BASE + 7200, model = "claude-sonnet-5", version = "2.1.232" }),
        { "CLAUDE.md" }
      )

      assert.equals(5, #causes)
      assert.truthy(causes[1]:find("TTL", 1, true))
      assert.truthy(causes[2]:find("model changed", 1, true))
      assert.truthy(causes[3]:find("CLAUDE.md", 1, true))
      assert.truthy(causes[4]:find("compacted", 1, true))
      assert.truthy(causes[5]:find("Claude Code was updated", 1, true))
    end)

    it("passes over a field that only one side knows", function()
      -- A record written before the field existed is indistinguishable from one where the value
      -- was genuinely unset, so an unset -> set transition must not be reported as a change.
      assert.same({}, PrefixRewrite.causes(facts({ effort = nil, version = nil }), facts({ at = BASE + 60 }), {}))
    end)
  end)

  describe("edited_prompt_sources", function()
    local dir, home

    before_each(function()
      dir = vim.fn.tempname()
      vim.fn.mkdir(dir .. "/.claude/rules", "p")
      vim.fn.mkdir(dir .. "/.vibing", "p")
      -- The user layer is scanned too, so it has to be injected: pointed at the real home these
      -- assertions would depend on when the developer last edited their own ~/.claude/rules.
      home = vim.fn.tempname()
      vim.fn.mkdir(home .. "/.claude/rules", "p")
    end)

    after_each(function()
      vim.fn.delete(dir, "rf")
      vim.fn.delete(home, "rf")
    end)

    --- @param root string
    --- @param rel string
    --- @param mtime number
    local function write_at(root, rel, mtime)
      local path = root .. "/" .. rel
      vim.fn.writefile({ "x" }, path)
      vim.uv.fs_utime(path, mtime, mtime)
    end

    it("reports only the sources touched after the given moment", function()
      write_at(dir, "CLAUDE.md", BASE + 100)
      write_at(dir, ".claude/rules/architecture.md", BASE - 100)
      write_at(dir, ".vibing/system-prompt.md", BASE + 200)

      local edited = PrefixRewrite.edited_prompt_sources(dir, BASE, home)

      table.sort(edited)
      assert.same({ ".vibing/system-prompt.md", "CLAUDE.md" }, edited)
    end)

    it("reports nothing when everything predates the last turn", function()
      write_at(dir, "CLAUDE.md", BASE - 100)

      assert.same({}, PrefixRewrite.edited_prompt_sources(dir, BASE, home))
    end)

    it("reports paths relative to the working directory", function()
      write_at(dir, ".claude/rules/permissions.md", BASE + 100)

      assert.same({ ".claude/rules/permissions.md" }, PrefixRewrite.edited_prompt_sources(dir, BASE, home))
    end)

    it("reports a user-level edit too, marked as one", function()
      -- A `~/.claude` edit invalidates even earlier than a project one, so leaving the layer out
      -- would report "no likely cause" for the case with the largest blast radius.
      write_at(home, ".claude/CLAUDE.md", BASE + 100)
      write_at(home, ".claude/rules/coding.md", BASE + 100)

      local edited = PrefixRewrite.edited_prompt_sources(dir, BASE, home)

      table.sort(edited)
      assert.same({ "~/.claude/CLAUDE.md", "~/.claude/rules/coding.md" }, edited)
    end)

    it("returns nothing rather than erroring on a missing directory", function()
      assert.same({}, PrefixRewrite.edited_prompt_sources(dir .. "/gone", BASE, home))
      assert.same({}, PrefixRewrite.edited_prompt_sources(nil, BASE, home))
      assert.same({}, PrefixRewrite.edited_prompt_sources(dir, nil, home))
    end)
  end)

  describe("note", function()
    local function detection(causes)
      return { write = 198000, causes = causes }
    end

    it("states the size rewritten and the single cause", function()
      local note = PrefixRewrite.note(detection({ "1h12m since the last turn (the prompt cache TTL is 1h)" }))

      assert.truthy(note:find("Prefix rewritten (198k)", 1, true))
      assert.truthy(note:find("Likely cause:", 1, true))
      assert.truthy(note:find("1h12m", 1, true))
    end)

    it("switches to the plural label and joins the causes", function()
      local note = PrefixRewrite.note(detection({ "one thing", "another thing" }))

      assert.truthy(note:find("Likely causes:", 1, true))
      assert.truthy(note:find("one thing; another thing.", 1, true))
    end)

    it("says so rather than inventing a cause it could not establish", function()
      local note = PrefixRewrite.note(detection({}))

      assert.truthy(note:find("No likely cause found", 1, true))
    end)

    it("renders as a blockquote that stays inside a readable width", function()
      local note = PrefixRewrite.note(detection({
        "1h12m since the last turn (the prompt cache TTL is 1h)",
        "CLAUDE.md, .claude/rules/architecture.md, .vibing/system-prompt.md edited since the last turn",
      }))

      for line in vim.gsplit(note, "\n") do
        assert.equals("> ", line:sub(1, 2))
        -- Display width, not bytes: the note always carries `↻`, and a byte budget would both
        -- report the wrong number here and let the implementation wrap far too early.
        assert.is_true(vim.fn.strdisplaywidth(line) <= 92, "line ran long: " .. line)
      end
    end)

    it("wraps on display width, so a wide file name does not shorten every line", function()
      local note = PrefixRewrite.note(detection({ ".claude/rules/" .. string.rep("あ", 20) .. ".md edited" }))
      local widest = 0

      for line in vim.gsplit(note, "\n") do
        widest = math.max(widest, vim.fn.strdisplaywidth(line))
      end

      -- A byte count would treat each CJK character as three columns and break the note into a
      -- narrow column; the wrap has to reach a usable width even so.
      assert.is_true(widest > 60, "wrapped far too narrow: " .. widest)
      assert.is_true(widest <= 92)
    end)

    it("returns nothing when there was no rewrite", function()
      assert.is_nil(PrefixRewrite.note(nil))
    end)
  end)
end)
