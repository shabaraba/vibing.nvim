local Eval = require("vibing.testing.chat_search_eval")

describe("chat search eval scoring", function()
  local case = { id = "x", query = "q", expected = { "a", "b" }, acceptable = { "c" }, distractors = { "d" } }

  it("counts what was missed and what was wrongly returned", function()
    local score = Eval.score(case, { "a", "c", "d" })

    assert.are.equal(0.5, score.recall)
    assert.are.equal(2 / 3, score.precision)
    assert.is_false(score.exact)
    assert.are.same({ "b" }, score.missed)
    assert.are.same({ "d" }, score.extra)
    assert.are.same({ "missed b", "extra  d (distractor)" }, Eval.format_attempt(case, score))
  end)

  it("names the stage a miss happened at when the candidates are known", function()
    local both = { id = "y", query = "q", expected = { "a", "b" }, acceptable = {}, distractors = {} }
    local score = Eval.score(both, {})

    assert.are.same(
      { "missed a (dropped at judgement)", "missed b (never a candidate)" },
      Eval.format_attempt(both, score, { "a", "z" })
    )
  end)

  it("does not penalise an acceptable chat", function()
    local score = Eval.score(case, { "a", "b", "c" })

    assert.are.equal(1, score.precision)
    assert.is_true(score.exact)
  end)

  it("treats an empty answer to a query with no match as exact", function()
    local none = { id = "n", query = "q", expected = {}, acceptable = {}, distractors = {} }

    assert.is_true(Eval.score(none, {}).exact)
    assert.are.equal(0, Eval.score(none, { "a" }).precision)
  end)

  it("scores a failed search as zero rather than as finding nothing", function()
    local score = Eval.failed(case, "rate limited")

    assert.are.same({ recall = 0, precision = 0, exact = 0, errors = 1, count = 1 }, Eval.summarize({ score }))
  end)
end)

describe("chat search eval cases", function()
  local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h:h")
  local corpus = root .. "/tests/fixtures/chat_search/corpus/"

  it("name only chats that exist in the corpus", function()
    for _, case in ipairs(require("tests.evals.chat_search.cases")) do
      for _, name in ipairs(vim.list_extend(vim.list_extend(vim.deepcopy(case.expected), case.acceptable), case.distractors)) do
        assert.are.equal(1, vim.fn.filereadable(corpus .. name), case.id .. ": " .. name)
      end
    end
  end)
end)
