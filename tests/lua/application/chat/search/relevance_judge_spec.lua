local RelevanceJudge = require("vibing.application.chat.search.relevance_judge")

---@param name string
---@param created_at integer
---@return table FileEntity の、判定が触る面だけを持つスタブ
local function entity(name, created_at)
  return {
    path = "/tmp/" .. name .. ".md",
    created_at = created_at,
    get_display_name = function()
      return name
    end,
    get_formatted_date = function()
      return os.date("%Y-%m-%d %H:%M:%S", created_at)
    end,
  }
end

---@param name string
---@param created_at integer
---@return Vibing.Chat.Search.Candidate
local function candidate(name, created_at)
  return { entity = entity(name, created_at), hits = 1, excerpt = { name .. " excerpt" } }
end

describe("chat search relevance judge", function()
  it("reads YES and NO verdicts out of the response", function()
    local verdicts = RelevanceJudge.parse("1|YES|URL表示の話\n2|NO|")

    assert.is_true(verdicts[1].relevant)
    assert.are.equal("URL表示の話", verdicts[1].summary)
    assert.is_false(verdicts[2].relevant)
  end)

  it("reads a bracketed index and a lower-case verdict", function()
    local verdicts = RelevanceJudge.parse("[3] | yes | something")

    assert.is_true(verdicts[3].relevant)
    assert.are.equal("something", verdicts[3].summary)
  end)

  it("keeps only the relevant candidates", function()
    local candidates = { candidate("a", 100), candidate("b", 200) }
    local results = RelevanceJudge.apply(candidates, {
      [1] = { relevant = true, summary = "about it" },
      [2] = { relevant = false, summary = "" },
    })

    assert.are.equal(1, #results)
    assert.are.equal("a", results[1].entity:get_display_name())
    assert.are.equal("about it", results[1].summary)
  end)

  it("drops a candidate the model said nothing about", function()
    local results = RelevanceJudge.apply({ candidate("a", 100) }, {})

    assert.are.same({}, results)
  end)

  it("returns the newest match first", function()
    local candidates = { candidate("old", 100), candidate("new", 999) }
    local results = RelevanceJudge.apply(candidates, {
      [1] = { relevant = true, summary = "" },
      [2] = { relevant = true, summary = "" },
    })

    assert.are.equal("new", results[1].entity:get_display_name())
  end)

  it("numbers every candidate in the prompt it builds", function()
    local prompt = RelevanceJudge.build_prompt("webfetch", { candidate("a", 100), candidate("b", 200) })

    assert.is_truthy(prompt:find("[1] a", 1, true))
    assert.is_truthy(prompt:find("[2] b", 1, true))
    assert.is_truthy(prompt:find("a excerpt", 1, true))
    assert.is_truthy(prompt:find("Search query: webfetch", 1, true))
  end)

  it("judges nothing when there is no candidate", function()
    local called
    RelevanceJudge.judge("q", {}, function(results, err)
      called = { results = results, err = err }
    end)

    assert.are.same({}, called.results)
    assert.is_nil(called.err)
  end)
end)
