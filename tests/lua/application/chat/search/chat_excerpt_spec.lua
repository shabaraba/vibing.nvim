local ChatExcerpt = require("vibing.application.chat.search.chat_excerpt")

describe("chat excerpt", function()
  local dir

  ---@param name string
  ---@param lines string[]
  ---@return string
  local function chat(name, lines)
    local path = dir .. "/" .. name
    vim.fn.writefile(lines, path)
    return path
  end

  before_each(function()
    dir = vim.fn.tempname() .. "_chat_excerpt"
    vim.fn.mkdir(dir, "p")
  end)

  after_each(function()
    vim.fn.delete(dir, "rf")
  end)

  it("titles a chat by its one-line summary, and dates it by created_at", function()
    local path = chat("chat-20260101-x.md", {
      "---",
      "created_at: 2026-07-08T14:22:33",
      "---",
      "## summary",
      "### 📝 一行要約",
      "",
      "タスクを復元できるようにした",
      "## User <!-- 2026-07-08 -->",
      "消したい",
    })

    local excerpt = ChatExcerpt.build(path, {})

    assert.are.equal("タスクを復元できるようにした", excerpt.title)
    assert.are.equal("2026-07-08", excerpt.date)
  end)

  it("falls back to the first user message and the date in the file name", function()
    local path = chat("chat-20260603-140210-x.md", { "# Vibing Chat", "## User <!-- t -->", "", "一覧が遅い" })

    local excerpt = ChatExcerpt.build(path, {})

    assert.are.equal("一覧が遅い", excerpt.title)
    assert.are.equal("2026-06-03", excerpt.date)
  end)

  it("shows the lines around a match and marks the gaps", function()
    local lines = {}
    for i = 1, 40 do
      lines[i] = "line " .. i
    end
    lines[10] = "the N+1 query"
    lines[30] = "an N+1 again"

    local text = ChatExcerpt.build(chat("a.md", lines), { "n+1" }).text

    assert.is_truthy(text:find("line 8\nline 9\nthe N+1 query\nline 11\nline 12\n…\nline 28", 1, true))
    assert.is_falsy(text:find("line 20", 1, true))
  end)

  it("stays within the budget, keeping the lines that match the most terms", function()
    local lines = {}
    for i = 1, 200 do
      lines[i] = string.rep("x", 100) .. " alpha"
    end
    lines[150] = "alpha beta"

    local text = ChatExcerpt.build(chat("a.md", lines), { "alpha", "beta" }).text

    assert.is_true(#text <= ChatExcerpt.MAX_CHARS + 20)
    assert.is_truthy(text:find("alpha beta", 1, true))
  end)
end)
