local CandidateFinder = require("vibing.application.chat.search.candidate_finder")
local Frontmatter = require("vibing.infrastructure.storage.frontmatter")

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
  local dir = vim.fn.tempname() .. "_chat_search"
  vim.fn.mkdir(dir, "p")
  return dir
end

describe("chat search candidate finder", function()
  it("drops blank and duplicate keywords, case-insensitively", function()
    assert.are.same({ "webfetch", "url表示" }, CandidateFinder.needles({ "WebFetch", "  ", "webfetch", "URL表示" }))
  end)

  it("finds no candidate when every keyword is blank", function()
    local dir = make_dir()
    write_chat(dir, "a", "\n## User\n\nWebFetch について\n")

    assert.are.same({}, CandidateFinder.find(dir, { "", "   " }))
  end)

  it("matches assistant content, not only user sections", function()
    local dir = make_dir()
    write_chat(dir, "assistant-side", "\n## User\n\nあれどうなった\n\n## Assistant\n\nWebFetch の URL を表示します\n")

    local candidates = CandidateFinder.find(dir, { "webfetch" })

    assert.are.equal(1, #candidates)
    assert.are.equal(1, candidates[1].hits)
  end)

  it("ranks the file with more hits first", function()
    local dir = make_dir()
    write_chat(dir, "few", "\n## User\n\nWebFetch\n")
    write_chat(dir, "many", "\n## User\n\nWebFetch\n\n## Assistant\n\nWebFetch\n\n## User\n\nwebfetch\n")

    local candidates = CandidateFinder.find(dir, { "webfetch" })

    assert.are.equal(2, #candidates)
    assert.are.equal("many", candidates[1].entity:get_display_name())
    assert.are.equal(3, candidates[1].hits)
  end)

  it("caps the candidate list at max_candidates", function()
    local dir = make_dir()
    for index = 1, 5 do
      write_chat(dir, "chat" .. index, "\n## User\n\nWebFetch\n")
    end

    assert.are.equal(2, #CandidateFinder.find(dir, { "webfetch" }, { max_candidates = 2 }))
  end)

  it("carries the surrounding lines into the excerpt", function()
    local dir = make_dir()
    write_chat(dir, "ctx", "\n## User\n\nbefore-line\nWebFetch here\nafter-line\n")

    local excerpt = CandidateFinder.find(dir, { "webfetch" })[1].excerpt

    assert.is_true(vim.tbl_contains(excerpt, "before-line"))
    assert.is_true(vim.tbl_contains(excerpt, "after-line"))
  end)

  it("ignores files that are not vibing chats", function()
    local dir = make_dir()
    vim.fn.writefile({ "# notes", "WebFetch" }, dir .. "/notes.md")

    assert.are.same({}, CandidateFinder.find(dir, { "webfetch" }))
  end)
end)
