local USE_CASE = "vibing.application.chat.use_cases.search_chats"
local AGENT = "vibing.application.chat.search.background_agent"

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

  ---@param value table
  ---@return string
  local function json(value)
    return "```json\n" .. vim.json.encode(value) .. "\n```"
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
      run = function(prompt, tools, _, callback, _, overrides)
        asked[#asked + 1] = { prompt = prompt, tools = tools, overrides = overrides or {} }
        local reply = table.remove(replies, 1) or {}
        callback(reply.text, reply.error)
      end,
    })
    package.loaded[USE_CASE] = nil
  end)

  after_each(function()
    package.loaded[AGENT] = nil
    package.loaded[USE_CASE] = nil
    vim.fn.delete(chat_dir, "rf")
  end)

  it("searches the terms the model chose and keeps the chats it picked", function()
    replies = {
      { text = json({ concepts = { { terms = { "論理削除", "soft delete" } } } }) },
      { text = json({ groups = { { label = "direct", chats = { { id = "C1", summary = "s" } } } } }) },
    }

    local outcome = run("論理削除")

    assert.is_nil(outcome.error)
    assert.are.equal(1, #outcome.results)
    assert.are.equal("a.md", vim.fn.fnamemodify(outcome.results[1].entity.path, ":t"))
    assert.are.equal("direct", outcome.results[1].group)
    assert.is_truthy(asked[2].prompt:find("soft delete にします", 1, true))
    assert.is_falsy(asked[2].prompt:find("prefers-color-scheme", 1, true))
  end)

  it("gives the model no tools in either step", function()
    replies = {
      { text = json({ concepts = { { terms = { "soft delete" } } } }) },
      { text = json({ groups = {} }) },
    }

    run("x")

    assert.are.equal(2, #asked)
    assert.is_nil(asked[1].tools)
    assert.is_nil(asked[2].tools)
  end)

  it("lets only the term step skip thinking, since judging without it missed chats", function()
    replies = {
      { text = json({ concepts = { { terms = { "soft delete" } } } }) },
      { text = json({ groups = {} }) },
    }

    run("x")

    assert.are.equal(false, asked[1].overrides.thinking)
    assert.is_nil(asked[2].overrides.thinking)
  end)

  it("asks nothing more when no chat contains a term", function()
    replies = { { text = json({ concepts = { { terms = { "kubernetes" } } } }) } }

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
