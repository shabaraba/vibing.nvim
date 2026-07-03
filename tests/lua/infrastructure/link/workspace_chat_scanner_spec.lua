-- tests/lua/infrastructure/link/workspace_chat_scanner_spec.lua
local WorkspaceChatScanner = require("vibing.infrastructure.link.workspace_chat_scanner")
local Meta = require("vibing.infrastructure.workspace.meta")

describe("vibing.infrastructure.link.workspace_chat_scanner", function()
  local base_dir
  local meta_path

  before_each(function()
    base_dir = vim.fn.tempname() .. "/workspace"
    vim.fn.mkdir(base_dir .. "/active/0001-fix-bug", "p")
    meta_path = base_dir .. "/active/0001-fix-bug/meta.yaml"
    Meta.write(meta_path, {
      workspace_id = "0001-fix-bug",
      branch = "fix-bug",
      chat_files = { ".vibing/chat/old-name.md" },
    })
  end)

  after_each(function()
    vim.fn.delete(base_dir, "rf")
  end)

  it("finds meta.yaml files under the workspace base dir", function()
    local scanner = WorkspaceChatScanner.new()
    local files = scanner:find_target_files(base_dir .. "/")
    assert.equals(1, #files)
    assert.is_truthy(files[1]:find("meta%.yaml$"))
  end)

  it("detects when a meta.yaml references the given chat file", function()
    local scanner = WorkspaceChatScanner.new()
    assert.is_true(scanner:contains_link(meta_path, ".vibing/chat/old-name.md"))
    assert.is_false(scanner:contains_link(meta_path, ".vibing/chat/other.md"))
  end)

  it("updates the chat_files entry in place", function()
    local scanner = WorkspaceChatScanner.new()
    local ok = scanner:update_link(meta_path, ".vibing/chat/old-name.md", ".vibing/chat/new-name.md")
    assert.is_true(ok)

    local data = Meta.read(meta_path)
    assert.same({ ".vibing/chat/new-name.md" }, data.chat_files)
  end)
end)
