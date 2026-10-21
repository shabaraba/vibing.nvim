local ChatGrep = require("vibing.application.chat.search.chat_grep")

describe("chat grep ranking", function()
  it("ranks a chat that matches more concepts above one that repeats a single word", function()
    local hits = {
      ["soft delete"] = { a = 1, c = 2 },
      ["検索"] = { a = 1, b = 1 },
    }
    local ranked = ChatGrep.rank(hits, { { "soft delete" }, { "検索" } }, 10)

    assert.are.same({ "a", "c", "b" }, vim.tbl_map(function(c)
      return c.path
    end, ranked))
  end)

  it("gives no weight to a term found in every chat", function()
    local hits = { ["タスク"] = { a = 5, b = 5 } }

    assert.are.same({}, ChatGrep.rank(hits, { { "タスク" } }, 2))
  end)

  it("counts a concept once, however many of its terms match", function()
    local one = ChatGrep.rank({ x = { a = 1 } }, { { "x" } }, 10)[1].score
    local many = ChatGrep.rank({ x = { a = 1 }, y = { a = 1 } }, { { "x", "y" } }, 10)[1].score

    assert.are.equal(one, many)
  end)

  it("remembers which terms matched each chat", function()
    local ranked = ChatGrep.rank({ x = { a = 1 }, y = { a = 2 } }, { { "x", "y" } }, 10)

    assert.are.same({ "x", "y" }, ranked[1].terms)
  end)

  it("keeps at most MAX_CANDIDATES", function()
    local per_file = {}
    for i = 1, ChatGrep.MAX_CANDIDATES + 5 do
      per_file["f" .. i] = i
    end

    assert.are.equal(ChatGrep.MAX_CANDIDATES, #ChatGrep.rank({ x = per_file }, { { "x" } }, 100))
  end)

  it("reads rg's count output, including a path with a colon", function()
    assert.are.same({ ["/d/a.md"] = 3, ["/d/b:c.md"] = 1 }, ChatGrep.parse_counts("/d/a.md:3\n/d/b:c.md:1\n"))
  end)
end)

describe("chat grep", function()
  local dir

  before_each(function()
    dir = vim.fn.tempname() .. "_chat_grep"
    vim.fn.mkdir(dir, "p")
    vim.fn.writefile({ "N+1 を直した" }, dir .. "/a.md")
    vim.fn.writefile({ "nothing" }, dir .. "/b.md")
    vim.fn.writefile({ ".vibing/" }, dir .. "/.gitignore")
  end)

  after_each(function()
    vim.fn.delete(dir, "rf")
  end)

  it("matches a term literally and case-insensitively", function()
    local found
    ChatGrep.run(dir, { { "n+1" } }, function(candidates)
      found = candidates
    end)
    vim.wait(5000, function()
      return found ~= nil
    end, 10)

    assert.are.same({ dir .. "/a.md" }, vim.tbl_map(function(c)
      return c.path
    end, found))
  end)
end)
