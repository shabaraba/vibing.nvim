local ForkedChatScanner = require("vibing.infrastructure.link.forked_chat_scanner")
local Frontmatter = require("vibing.infrastructure.storage.frontmatter")
local Git = require("vibing.core.utils.git")

---@param dir string
---@param name string
---@param frontmatter table
---@return string path
local function write_chat(dir, name, frontmatter)
  local path = dir .. "/" .. name
  local defaults = { ["vibing.nvim"] = true, session_id = "session-" .. name }
  for k, v in pairs(frontmatter) do
    defaults[k] = v
  end
  vim.fn.writefile(vim.split(Frontmatter.serialize(defaults, "## User\n"), "\n", { plain = true }), path)
  return path
end

---@param path string
---@return table
local function read_frontmatter(path)
  return (Frontmatter.parse(table.concat(vim.fn.readfile(path), "\n")))
end

describe("ForkedChatScanner", function()
  local dir
  local original_get_root

  before_each(function()
    dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    original_get_root = Git.get_root
    Git.get_root = function()
      return dir
    end
  end)

  after_each(function()
    Git.get_root = original_get_root
    vim.fn.delete(dir, "rf")
  end)

  it("finds a fork that points at the renamed source", function()
    local source = dir .. "/source.md"
    local fork = write_chat(dir, "fork.md", { forked_from = "source.md" })

    assert.is_true(ForkedChatScanner.new():contains_link(fork, source))
  end)

  it("ignores a chat with no forked_from", function()
    local other = write_chat(dir, "other.md", {})

    assert.is_false(ForkedChatScanner.new():contains_link(other, dir .. "/source.md"))
  end)

  it("ignores a fork that points somewhere else", function()
    local fork = write_chat(dir, "fork.md", { forked_from = "elsewhere.md" })

    assert.is_false(ForkedChatScanner.new():contains_link(fork, dir .. "/source.md"))
  end)

  it("rewrites forked_from to the new display path", function()
    local fork = write_chat(dir, "fork.md", { forked_from = "source.md" })

    local ok = ForkedChatScanner.new():update_link(fork, dir .. "/source.md", dir .. "/renamed.md")

    assert.is_true(ok)
    assert.equals("renamed.md", read_frontmatter(fork).forked_from)
  end)

  it("replaces the whole key, which is why a list field needs its own scanner", function()
    -- `forked_from` はスカラーなので `Frontmatter.update` にキーごと渡して問題ない。
    -- 同じ実装をリスト（orchestrated / orchestrated_by）に流用すると他の要素が消えるため、
    -- `OrchestrationChatScanner` は要素単位で書き換えている
    local fork = write_chat(dir, "fork.md", { forked_from = "source.md" })

    ForkedChatScanner.new():update_link(fork, dir .. "/source.md", dir .. "/renamed.md")

    local frontmatter = read_frontmatter(fork)
    assert.equals("renamed.md", frontmatter.forked_from)
    assert.is_true(frontmatter["vibing.nvim"])
  end)

  it("reports a failure when there is no forked_from to update", function()
    local other = write_chat(dir, "other.md", {})

    local ok, err = ForkedChatScanner.new():update_link(other, dir .. "/source.md", dir .. "/renamed.md")

    assert.is_false(ok)
    assert.equals("No forked_from field", err)
  end)

  it("returns nothing for a directory that does not exist", function()
    assert.same({}, ForkedChatScanner.new():find_target_files(dir .. "/missing/"))
  end)
end)
