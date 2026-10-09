local USE_CASE = "vibing.application.chat.use_cases.search_chats"
local AGENT = "vibing.application.chat.search.background_agent"

describe("search chats", function()
  local chat_dir
  local asked
  local reply

  ---@param query string
  ---@return Vibing.Chat.Search.Outcome
  local function run(query)
    local outcome
    require(USE_CASE).run(query, chat_dir, function(o)
      outcome = o
    end)
    return outcome
  end

  before_each(function()
    chat_dir = vim.fn.tempname() .. "_search_chats"
    vim.fn.mkdir(chat_dir, "p")
    asked = {}
    reply = {}

    local real = require(AGENT)
    package.loaded[AGENT] = vim.tbl_extend("force", real, {
      language_name = function()
        return nil
      end,
      run = function(prompt, tools, _, callback)
        asked[#asked + 1] = { prompt = prompt, tools = tools }
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

  it("returns the chats the agent picked", function()
    vim.fn.writefile({ "---", "vibing.nvim: true", "---" }, chat_dir .. "/a.md")
    reply.text = "```json\n"
      .. vim.json.encode({ groups = { { label = "direct", chats = { { path = chat_dir .. "/a.md" } } } } })
      .. "\n```"

    local outcome = run("pull/70332")

    assert.is_nil(outcome.error)
    assert.are.equal("direct", outcome.results[1].group)
    assert.is_truthy(asked[1].prompt:find("pull/70332", 1, true))
    assert.are.same(require("vibing.application.chat.search.chat_prompt").TOOLS, asked[1].tools)
  end)

  it("reports a failed turn instead of an empty result", function()
    reply.error = "rate limited"

    local outcome = run("x")

    assert.are.equal("rate limited", outcome.error)
    assert.are.same({}, outcome.results)
  end)

  it("reports an answer it cannot read", function()
    reply.text = "I could not decide."

    assert.is_not_nil(run("x").error)
  end)
end)
