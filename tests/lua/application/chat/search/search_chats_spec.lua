local USE_CASE = "vibing.application.chat.use_cases.search_chats"
local AGENT = "vibing.application.chat.search.background_agent"
local HELPER = "vibing.application.chat.search.helper_answer"

describe("search chats", function()
  local chat_dir
  local asked
  local replies

  ---@param query string
  ---@return Vibing.Chat.Search.Outcome
  local function run(query)
    local outcome
    require(USE_CASE).run(query, chat_dir, function(o)
      outcome = o
    end)
    vim.wait(5000, function()
      return outcome ~= nil
    end, 10)
    return outcome
  end

  before_each(function()
    chat_dir = vim.fn.tempname() .. "_search_chats"
    vim.fn.mkdir(chat_dir, "p")
    vim.fn.writefile({ "## User", "消したタスクを戻したい", "## Assistant", "soft delete にします" }, chat_dir .. "/a.md")
    vim.fn.writefile({ "## User", "ダークモード", "## Assistant", "prefers-color-scheme" }, chat_dir .. "/b.md")
    asked = {}
    replies = {}

    local real = require(AGENT)
    package.loaded[AGENT] = vim.tbl_extend("force", real, {
      language_name = function()
        return nil
      end,
    })
    package.loaded[HELPER] = {
      ask = function(prompt, schema, callback, call)
        asked[#asked + 1] = { prompt = prompt, schema = schema, call = call or {} }
        local reply = table.remove(replies, 1) or {}
        callback(reply.value, reply.error)
      end,
    }
    package.loaded[USE_CASE] = nil
  end)

  after_each(function()
    package.loaded[AGENT] = nil
    package.loaded[HELPER] = nil
    package.loaded[USE_CASE] = nil
    vim.fn.delete(chat_dir, "rf")
  end)

  it("searches the terms the model chose and keeps the chats it picked", function()
    replies = {
      { value = { concepts = { { terms = { "論理削除", "soft delete" } } } } },
      { value = { groups = { { label = "direct", chats = { { id = "C1", summary = "s" } } } } } },
    }

    local outcome = run("論理削除")

    assert.is_nil(outcome.error)
    assert.are.equal(1, #outcome.results)
    assert.are.equal("a.md", vim.fn.fnamemodify(outcome.results[1].entity.path, ":t"))
    assert.are.equal("direct", outcome.results[1].group)
    assert.is_truthy(asked[2].prompt:find("soft delete にします", 1, true))
    assert.is_falsy(asked[2].prompt:find("prefers-color-scheme", 1, true))
  end)

  it("asks for terms, then for a judgement, each in its own schema", function()
    replies = {
      { value = { concepts = { { terms = { "soft delete" } } } } },
      { value = { groups = {} } },
    }

    run("x")

    assert.are.equal(2, #asked)
    assert.are.equal(require("vibing.application.chat.search.query_terms").SCHEMA, asked[1].schema)
    assert.are.equal(require("vibing.application.chat.search.chat_judgement").SCHEMA, asked[2].schema)
  end)

  it("lets only the term step skip thinking, since judging without it missed chats", function()
    replies = {
      { value = { concepts = { { terms = { "soft delete" } } } } },
      { value = { groups = {} } },
    }

    run("x")

    assert.are.equal(false, asked[1].call.thinking)
    assert.is_nil(asked[2].call.thinking)
  end)

  it("asks nothing more when no chat contains a term", function()
    replies = { { value = { concepts = { { terms = { "kubernetes" } } } } } }

    local outcome = run("x")

    assert.are.same({ results = {} }, outcome)
    assert.are.equal(1, #asked)
  end)

  it("reports a failed step instead of an empty result", function()
    replies = { { error = "rate limited" } }

    local outcome = run("x")

    assert.are.equal("rate limited", outcome.error)
    assert.are.same({}, outcome.results)
  end)
end)
