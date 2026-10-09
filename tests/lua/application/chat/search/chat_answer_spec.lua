local AgentAnswer = require("vibing.application.chat.search.chat_answer")

---@return string root 作業ディレクトリに見立てた場所
---@return string chat_dir その下のチャット置き場
local function make_dirs()
  local root = vim.fn.tempname() .. "_agent_answer"
  local chat_dir = root .. "/.vibing/chat"
  vim.fn.mkdir(chat_dir, "p")
  return root, chat_dir
end

---@param dir string
---@param name string
---@return string path
local function write_chat(dir, name)
  local path = dir .. "/" .. name .. ".md"
  vim.fn.writefile({ "---", "vibing.nvim: true", "---", "", "## User", "", "hi" }, path)
  return path
end

---@param groups table
---@return string
local function answer(groups)
  return "I searched.\n```json\n" .. vim.json.encode({ groups = groups }) .. "\n```\n"
end

---@param results Vibing.Chat.Search.Result[]
---@return string[]
local function names(results)
  return vim.tbl_map(function(result)
    return result.group .. ":" .. result.entity.display_name
  end, results)
end

describe("chat search answer", function()
  local root, chat_dir

  before_each(function()
    root, chat_dir = make_dirs()
  end)

  after_each(function()
    vim.fn.delete(root, "rf")
  end)

  it("keeps the groups in the order the agent gave them", function()
    write_chat(chat_dir, "a")
    write_chat(chat_dir, "b")
    write_chat(chat_dir, "c")

    local results = AgentAnswer.parse(
      answer({
        { label = "direct", chats = { { path = chat_dir .. "/b.md", summary = "made the PR" } } },
        { label = "later", chats = { { path = chat_dir .. "/a.md", summary = "x" }, { path = chat_dir .. "/c.md" } } },
      }),
      chat_dir,
      root
    )

    assert.are.same({ "direct:b", "later:a", "later:c" }, names(results))
    assert.are.equal("made the PR", results[1].summary)
    assert.are.equal("", results[3].summary)
  end)

  it("resolves a path relative to where the agent ran, or to the chat directory", function()
    write_chat(chat_dir, "a")
    write_chat(chat_dir, "b")

    local results = AgentAnswer.parse(
      answer({ { label = "g", chats = { { path = ".vibing/chat/a.md" }, { path = "b.md" } } } }),
      chat_dir,
      root
    )

    assert.are.same({ "g:a", "g:b" }, names(results))
  end)

  it("drops a file outside the chat directory, a missing one and a repeat", function()
    write_chat(chat_dir, "a")
    local outside = write_chat(root, "outside")

    local results = AgentAnswer.parse(
      answer({
        { label = "g", chats = { { path = outside }, { path = chat_dir .. "/gone.md" }, { path = "a.md" } } },
        { label = "h", chats = { { path = chat_dir .. "/a.md" } } },
      }),
      chat_dir,
      root
    )

    assert.are.same({ "g:a" }, names(results))
  end)

  it("reads the last JSON block, not an example earlier in the text", function()
    write_chat(chat_dir, "a")
    local text = '```json\n{"groups": [{"label": "example", "chats": []}]}\n```\nthen\n'
      .. answer({ { label = "real", chats = { { path = "a.md" } } } })

    assert.are.same({ "real:a" }, names(AgentAnswer.parse(text, chat_dir, root)))
  end)

  it("folds a multi-line summary into one line", function()
    write_chat(chat_dir, "a")

    local results = AgentAnswer.parse(
      answer({ { label = "g", chats = { { path = "a.md", summary = "first\n  second" } } } }),
      chat_dir,
      root
    )

    assert.are.equal("first second", results[1].summary)
  end)

  it("returns an empty list when the agent found nothing", function()
    local results, err = AgentAnswer.parse(answer({}), chat_dir, root)

    assert.are.same({}, results)
    assert.is_nil(err)
  end)

  it("reports an answer with no JSON, or a malformed one", function()
    local _, missing = AgentAnswer.parse("nothing here", chat_dir, root)
    local _, malformed = AgentAnswer.parse('```json\n{"chats": 1}\n```', chat_dir, root)

    assert.is_not_nil(missing)
    assert.is_not_nil(malformed)
  end)
end)
