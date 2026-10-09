local Frontmatter = require("vibing.infrastructure.storage.frontmatter")

local LLM_MODULE = "vibing.application.chat.search.llm"
local RELOADED = {
  "vibing.application.chat.search.keyword_expander",
  "vibing.application.chat.search.relevance_judge",
  "vibing.application.chat.use_cases.search_chats",
}

---軽量呼び出しだけを差し替える。展開と判定の2回呼ばれるので、応答は順番に返す
---@param replies ({text: string?, error: string?})[]
---@return table requests 送られたプロンプト
local function stub_llm(replies)
  local real = require(LLM_MODULE)
  local requests = {}
  local index = 0

  package.loaded[LLM_MODULE] = {
    meaningful_lines = real.meaningful_lines,
    language_name = function()
      return nil
    end,
    request = function(prompt, callback)
      index = index + 1
      requests[#requests + 1] = prompt
      local reply = replies[index] or { error = "no reply configured" }
      callback(reply.text, reply.error)
    end,
  }

  for _, name in ipairs(RELOADED) do
    package.loaded[name] = nil
  end

  return requests
end

---@param dir string
---@param name string
---@param body string
local function write_chat(dir, name, body)
  local content = Frontmatter.serialize({
    ["vibing.nvim"] = true,
    session_id = "session-" .. name,
    created_at = "2025-01-01T00:00:00",
  }, body)
  vim.fn.writefile(vim.split(content, "\n"), dir .. "/" .. name .. ".md")
end

---@return string
local function make_dir()
  local dir = vim.fn.tempname() .. "_chat_search_usecase"
  vim.fn.mkdir(dir, "p")
  return dir
end

---@param replies ({text: string?, error: string?})[]
---@param dir string
---@param query string?
---@return Vibing.Chat.Search.Outcome outcome
---@return table requests
---@return integer[] steps
local function run(replies, dir, query)
  local requests = stub_llm(replies)
  local SearchChats = require("vibing.application.chat.use_cases.search_chats")

  local outcome, steps = nil, {}
  SearchChats.run(query or "webfetchのURL表示", dir, function(result)
    outcome = result
  end, {
    on_step = function(index)
      steps[#steps + 1] = index
    end,
  })

  return outcome, requests, steps
end

describe("chat search use case", function()
  after_each(function()
    package.loaded[LLM_MODULE] = nil
    for _, name in ipairs(RELOADED) do
      package.loaded[name] = nil
    end
  end)

  it("greps the expanded keywords and returns the judged summary", function()
    local dir = make_dir()
    write_chat(dir, "hit", "\n## Assistant\n\n閲覧したurl を出すようにした\n")
    write_chat(dir, "miss", "\n## User\n\n無関係な話\n")

    local outcome = run({
      { text = "webfetch\n閲覧したurl" },
      { text = "1|YES|URL表示を出すようにした話" },
    }, dir)

    assert.are.same({ "webfetch", "閲覧したurl" }, outcome.keywords)
    assert.are.equal(1, #outcome.results)
    assert.are.equal("hit", outcome.results[1].entity:get_display_name())
    assert.are.equal("URL表示を出すようにした話", outcome.results[1].summary)
    assert.is_nil(outcome.degraded)
  end)

  it("falls back to the raw query when expansion fails", function()
    local dir = make_dir()
    write_chat(dir, "hit", "\n## User\n\nwebfetch の話\n")

    local outcome = run({
      { error = "adapter exploded" },
      { text = "1|YES|それ" },
    }, dir, "webfetch")

    assert.are.same({ "webfetch" }, outcome.keywords)
    assert.are.equal(1, #outcome.results)
    assert.are.equal("adapter exploded", outcome.degraded)
  end)

  it("reports the raw matches when the relevance step fails", function()
    local dir = make_dir()
    write_chat(dir, "hit", "\n## User\n\nwebfetch の話\n")

    local outcome = run({
      { text = "webfetch" },
      { error = "judge exploded" },
    }, dir)

    assert.are.equal("judge exploded", outcome.degraded)
    assert.are.equal(1, #outcome.results)
    assert.are.equal("", outcome.results[1].summary)
  end)

  it("never reads the candidates when nothing matched", function()
    local dir = make_dir()
    write_chat(dir, "miss", "\n## User\n\n無関係な話\n")

    local outcome, requests, steps = run({ { text = "webfetch" } }, dir)

    assert.are.same({}, outcome.results)
    assert.are.equal(1, #requests)
    assert.are.same({ 1, 2 }, steps)
  end)

  it("walks the three steps in order", function()
    local dir = make_dir()
    write_chat(dir, "hit", "\n## User\n\nwebfetch の話\n")

    local _, _, steps = run({ { text = "webfetch" }, { text = "1|YES|x" } }, dir)

    assert.are.same({ 1, 2, 3 }, steps)
  end)
end)
