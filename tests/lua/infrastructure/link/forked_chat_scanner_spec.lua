local ForkedChatScanner = require("vibing.infrastructure.link.forked_chat_scanner")
local Frontmatter = require("vibing.infrastructure.storage.frontmatter")
local ChatFiles = require("tests.helpers.chat_files")
local Git = require("vibing.core.utils.git")

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
    local fork = ChatFiles.write(dir, "fork.md", { forked_from = "source.md" })

    assert.is_true(ForkedChatScanner.new():contains_link(fork, source))
  end)

  it("ignores a chat with no forked_from", function()
    local other = ChatFiles.write(dir, "other.md", {})

    assert.is_false(ForkedChatScanner.new():contains_link(other, dir .. "/source.md"))
  end)

  it("ignores a fork that points somewhere else", function()
    local fork = ChatFiles.write(dir, "fork.md", { forked_from = "elsewhere.md" })

    assert.is_false(ForkedChatScanner.new():contains_link(fork, dir .. "/source.md"))
  end)

  it("rewrites forked_from to the new display path", function()
    local fork = ChatFiles.write(dir, "fork.md", { forked_from = "source.md" })

    local ok = ForkedChatScanner.new():update_link(fork, dir .. "/source.md", dir .. "/renamed.md")

    assert.is_true(ok)
    assert.equals("renamed.md", ChatFiles.read_frontmatter(fork).forked_from)
  end)

  it("follows another scalar path field when told to", function()
    -- `:VibingChatHandoff` の `continued_from` は forked_from と同じ形なので同じスキャナーで追う
    local handoff = ChatFiles.write(dir, "handoff.md", { continued_from = "source.md" })
    local scanner = ForkedChatScanner.new("continued_from")

    assert.is_true(scanner:contains_link(handoff, dir .. "/source.md"))
    -- 既定のスキャナーは forked_from しか見ない
    assert.is_false(ForkedChatScanner.new():contains_link(handoff, dir .. "/source.md"))

    assert.is_true(scanner:update_link(handoff, dir .. "/source.md", dir .. "/renamed.md"))
    local frontmatter = ChatFiles.read_frontmatter(handoff)
    assert.equals("renamed.md", frontmatter.continued_from)
    assert.is_nil(frontmatter.forked_from)
  end)

  it("replaces the whole key, which is why a list field needs its own scanner", function()
    -- `forked_from` はスカラーなので `Frontmatter.update` にキーごと渡して問題ない。
    -- 同じ実装をリスト（orchestrated / orchestrated_by）に流用すると他の要素が消えるため、
    -- `OrchestrationChatScanner` は要素単位で書き換えている
    local fork = ChatFiles.write(dir, "fork.md", { forked_from = "source.md" })

    ForkedChatScanner.new():update_link(fork, dir .. "/source.md", dir .. "/renamed.md")

    local frontmatter = ChatFiles.read_frontmatter(fork)
    assert.equals("renamed.md", frontmatter.forked_from)
    assert.is_true(frontmatter["vibing.nvim"])
  end)

  it("reports a failure when there is no forked_from to update", function()
    local other = ChatFiles.write(dir, "other.md", {})

    local ok, err = ForkedChatScanner.new():update_link(other, dir .. "/source.md", dir .. "/renamed.md")

    assert.is_false(ok)
    assert.equals("No forked_from field", err)
  end)

  it("returns nothing for a directory that does not exist", function()
    assert.same({}, ForkedChatScanner.new():find_target_files(dir .. "/missing/"))
  end)
end)
