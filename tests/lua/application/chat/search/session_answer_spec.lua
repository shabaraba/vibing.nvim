local SessionAnswer = require("vibing.application.chat.search.session_answer")

---@param groups table
---@return string
local function answer(groups)
  return "Searched.\n```json\n" .. vim.json.encode({ groups = groups }) .. "\n```\n"
end

---@param overrides table?
---@return table
local function session(overrides)
  return vim.tbl_extend("force", {
    backend = "claude",
    session_id = "abc",
    cwd = "/repo",
    updated_at = "2026-10-09T05:12:33.000Z",
    title = "oauth",
    summary = "fixed it",
  }, overrides or {})
end

describe("session search answer", function()
  it("keeps the groups in the order the agent gave them", function()
    local results = SessionAnswer.parse(answer({
      { label = "direct", sessions = { session({ session_id = "b" }) } },
      { label = "later", sessions = { session({ session_id = "a", backend = "codex" }) } },
    }))

    assert.are.same({ "direct", "later" }, vim.tbl_map(function(r)
      return r.group
    end, results))
    assert.are.equal("codex", results[2].backend)
    assert.are.equal("/repo", results[1].cwd)
  end)

  it("drops an unknown backend, a missing id and a repeat", function()
    local results = SessionAnswer.parse(answer({
      { label = "g", sessions = { session({ backend = "grok" }), session({ session_id = "" }), session() } },
      { label = "h", sessions = { session() } },
    }))

    assert.are.equal(1, #results)
    assert.are.equal("g", results[1].group)
  end)

  it("keeps the same id on two CLIs apart", function()
    local results = SessionAnswer.parse(answer({
      { label = "g", sessions = { session(), session({ backend = "codex" }) } },
    }))

    assert.are.equal(2, #results)
  end)

  it("leaves an unknown cwd as nil and folds a multi-line summary", function()
    local results = SessionAnswer.parse(answer({
      { label = "g", sessions = { session({ cwd = "", summary = "a\n  b" }) } },
    }))

    assert.is_nil(results[1].cwd)
    assert.are.equal("a b", results[1].summary)
  end)

  it("reports an answer with no groups", function()
    local _, err = SessionAnswer.parse('```json\n{"sessions": []}\n```')

    assert.is_not_nil(err)
  end)

  describe("short_date", function()
    it("turns a UTC timestamp into local time", function()
      local stamp = os.time({ year = 2026, month = 10, day = 9, hour = 5, min = 12, sec = 33 })
      local offset = os.difftime(stamp, os.time(os.date("!*t", stamp) --[[@as osdateparam]]))

      assert.are.equal(
        os.date("%Y-%m-%d %H:%M", stamp + offset),
        SessionAnswer.short_date("2026-10-09T05:12:33.000Z")
      )
    end)

    it("reads a timestamp with no zone as local time", function()
      assert.are.equal("2026-10-09 05:12", SessionAnswer.short_date("2026-10-09T05:12:33"))
    end)

    it("leaves what it cannot read alone", function()
      assert.are.equal("yesterday", SessionAnswer.short_date("yesterday"))
    end)
  end)
end)
