local ChatJudgement = require("vibing.application.chat.search.chat_judgement")
local QueryTerms = require("vibing.application.chat.search.query_terms")
local GithubReference = require("vibing.application.chat.search.github_reference")

describe("chat judgement", function()
  local dir, candidates

  before_each(function()
    dir = vim.fn.tempname() .. "_chat_judgement"
    vim.fn.mkdir(dir, "p")
    vim.fn.writefile({ "a" }, dir .. "/a.md")
    vim.fn.writefile({ "b" }, dir .. "/b.md")
    candidates = { { path = dir .. "/a.md" }, { path = dir .. "/b.md" }, { path = dir .. "/gone.md" } }
  end)

  after_each(function()
    vim.fn.delete(dir, "rf")
  end)

  it("drops a chat that disappeared before the answer came back", function()
    assert.are.same({}, ChatJudgement.parse({ groups = { { label = "x", chats = { { id = "C3" } } } } }, candidates))
  end)

  it("maps the ids it gets back to the candidates, in the order given", function()
    local results = ChatJudgement.parse({
      groups = {
        { label = "direct", chats = { { id = "C2", summary = "two" } } },
        { label = "follow\nup", chats = { { id = "c1", summary = "one" } } },
      },
    }, candidates)

    assert.are.same({ dir .. "/b.md", dir .. "/a.md" }, vim.tbl_map(function(r)
      return r.entity.path
    end, results))
    assert.are.same({ "direct", "follow up" }, vim.tbl_map(function(r)
      return r.group
    end, results))
  end)

  it("drops an id it never offered, and a repeat", function()
    local results = ChatJudgement.parse(
      { groups = { { label = "x", chats = { { id = "C9" }, { id = "C1" }, { id = "C1" }, { path = "/d/b.md" } } } } },
      candidates
    )

    assert.are.equal(1, #results)
  end)

  it("reports a result without groups", function()
    local _, err = ChatJudgement.parse({ chats = {} }, candidates)

    assert.is_not_nil(err)
  end)

  it("numbers the candidates in the prompt", function()
    local prompt = ChatJudgement.build("q", { { date = "2026-01-01", title = "t", text = "body" } }, "lang")

    assert.is_truthy(prompt:find("### C1 (2026-01-01) t\nbody", 1, true))
  end)
end)

describe("query terms", function()
  it("trims, de-duplicates and caps the terms of each concept", function()
    local many = {}
    for i = 1, 20 do
      many[i] = "t" .. i
    end
    local concepts = QueryTerms.parse({ concepts = { { terms = { " Soft delete ", "soft DELETE", "", 3 } }, { terms = many } } })

    assert.are.same({ "Soft delete" }, concepts[1])
    assert.are.equal(10, #concepts[2])
  end)

  it("reports an answer with no usable term", function()
    local concepts, err = QueryTerms.parse({ concepts = { { terms = {} } } })

    assert.is_nil(concepts)
    assert.is_not_nil(err)
  end)
end)

describe("github reference", function()
  it("reads a PR or issue number from a URL or a mention", function()
    assert.are.same({ "pr", "70332" }, { GithubReference.parse("https://github.com/o/r/pull/70332") })
    assert.are.same({ "issue", "12" }, { GithubReference.parse("https://github.com/o/r/issues/12") })
    assert.are.same({ "pr", "886" }, { GithubReference.parse("PR 886 の件") })
    assert.are.same({ nil, "879" }, { GithubReference.parse("#879 どうなった") })
  end)

  it("does not take a plain number for one", function()
    assert.are.same({ nil, nil }, { GithubReference.parse("期限日が1日ずれる") })
  end)
end)
