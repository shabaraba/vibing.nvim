-- Tests for vibing.application.chat.handlers.template
-- Regression: CLAUDE.md detection must check the chat's own (worktree-aware)
-- cwd, not the Neovim process's git root, since those differ for a chat
-- attached to a git worktree.

describe("vibing.application.chat.handlers.template", function()
  local handler
  local checked_paths
  local original_filereadable
  local original_expand

  before_each(function()
    package.loaded["vibing.application.chat.handlers.template"] = nil
    package.loaded["vibing.core.utils.git"] = nil
    package.loaded["vibing.domain.chat.prompt_template"] = nil

    package.loaded["vibing.core.utils.git"] = {
      get_root = function()
        return "/repo/root"
      end,
      to_display_path = function(path)
        return path
      end,
    }

    package.loaded["vibing.domain.chat.prompt_template"] = {
      build = function(_, context_lines)
        return table.concat(context_lines, "\n")
      end,
    }

    checked_paths = {}
    original_filereadable = vim.fn.filereadable
    original_expand = vim.fn.expand

    vim.fn.filereadable = function(path)
      table.insert(checked_paths, path)
      return path == "/repo/root/.vibing/worktrees/feature-x/CLAUDE.md" and 1 or 0
    end
    vim.fn.expand = function(path)
      if path == "~/.claude/CLAUDE.md" then
        return "/home/user/.claude/CLAUDE.md"
      end
      return path
    end

    handler = require("vibing.application.chat.handlers.template")
  end)

  after_each(function()
    vim.fn.filereadable = original_filereadable
    vim.fn.expand = original_expand
    package.loaded["vibing.core.utils.git"] = nil
    package.loaded["vibing.domain.chat.prompt_template"] = nil
  end)

  it("checks CLAUDE.md at the chat's cwd, not the process git root", function()
    local chat_buffer = {
      get_cwd = function()
        return "/repo/root/.vibing/worktrees/feature-x"
      end,
    }

    local ok, draft = handler({ "worktree task" }, chat_buffer)

    assert.is_true(ok)
    assert.is_not_nil(draft:match("既存の規約"))
    assert.is_true(vim.tbl_contains(checked_paths, "/repo/root/.vibing/worktrees/feature-x/CLAUDE.md"))
    assert.is_false(vim.tbl_contains(checked_paths, "/repo/root/CLAUDE.md"))
  end)

  it("does not claim CLAUDE.md exists when only the git root (not cwd) has one", function()
    vim.fn.filereadable = function(path)
      table.insert(checked_paths, path)
      return path == "/repo/root/CLAUDE.md" and 1 or 0
    end

    local chat_buffer = {
      get_cwd = function()
        return "/repo/root/.vibing/worktrees/feature-x"
      end,
    }

    local ok, draft = handler({ "worktree task" }, chat_buffer)

    assert.is_true(ok)
    assert.is_nil(draft:match("既存の規約"))
  end)
end)
