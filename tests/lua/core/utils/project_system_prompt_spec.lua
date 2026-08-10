local project_system_prompt = require("vibing.core.utils.project_system_prompt")

describe("project_system_prompt", function()
  local project_root
  local original_notify

  local function write_prompt(root, content)
    vim.fn.mkdir(root .. "/.vibing", "p")
    vim.fn.writefile(vim.split(content, "\n", { plain = true }), root .. "/.vibing/system-prompt.md")
  end

  before_each(function()
    project_root = vim.fn.tempname()
    vim.fn.mkdir(project_root, "p")
    original_notify = vim.notify
    vim.notify = function() end
  end)

  after_each(function()
    vim.notify = original_notify
    vim.fn.delete(project_root, "rf")
  end)

  describe("read", function()
    it("returns nil when the file is missing", function()
      assert.is_nil(project_system_prompt.read(project_root))
    end)

    it("returns nil for an empty or whitespace-only file", function()
      write_prompt(project_root, "")
      assert.is_nil(project_system_prompt.read(project_root))

      write_prompt(project_root, "  \n\t\n")
      assert.is_nil(project_system_prompt.read(project_root))
    end)

    it("returns the trimmed contents", function()
      write_prompt(project_root, "Prefer pnpm.\nNever edit generated/.")
      assert.equals("Prefer pnpm.\nNever edit generated/.", project_system_prompt.read(project_root))
    end)

    it("truncates oversized content without splitting a multibyte character", function()
      -- 3-byte characters don't line up with the 8 KiB limit, so a naive byte cut
      -- would leave a half-written character at the boundary.
      local content = string.rep("あ", 4000)
      write_prompt(project_root, content)

      local result = project_system_prompt.read(project_root)
      assert.is_not_nil(result)
      assert.is_true(#result <= 8 * 1024)
      -- Every byte survives as valid UTF-8: the string is a whole number of characters
      assert.equals(0, #result % 3)
      assert.equals(#result / 3, vim.fn.strchars(result))
    end)

    it("truncates ASCII content exactly at the limit", function()
      write_prompt(project_root, string.rep("a", 9000))
      assert.equals(8 * 1024, #project_system_prompt.read(project_root))
    end)
  end)

  describe("read_for_cwd", function()
    local worktree_root
    local original_getcwd

    before_each(function()
      worktree_root = project_root .. "/.vibing/worktrees/feature-x"
      vim.fn.mkdir(worktree_root, "p")
      original_getcwd = vim.fn.getcwd
      vim.fn.getcwd = function()
        return project_root
      end
    end)

    after_each(function()
      vim.fn.getcwd = original_getcwd
    end)

    it("prefers the request cwd's file", function()
      write_prompt(project_root, "Root rule.")
      write_prompt(worktree_root, "Worktree rule.")
      assert.equals("Worktree rule.", project_system_prompt.read_for_cwd(worktree_root))
    end)

    it("falls back to the Neovim root when the cwd has no usable file", function()
      write_prompt(project_root, "Root rule.")
      assert.equals("Root rule.", project_system_prompt.read_for_cwd(worktree_root))

      write_prompt(worktree_root, "   ")
      assert.equals("Root rule.", project_system_prompt.read_for_cwd(worktree_root))
    end)

    it("uses the Neovim root when no cwd is given", function()
      write_prompt(project_root, "Root rule.")
      assert.equals("Root rule.", project_system_prompt.read_for_cwd(nil))
      assert.equals("Root rule.", project_system_prompt.read_for_cwd(""))
    end)

    it("returns nil when neither location has a file", function()
      assert.is_nil(project_system_prompt.read_for_cwd(worktree_root))
    end)
  end)

  describe("ensure", function()
    it("creates an empty file that read() treats as unset", function()
      project_system_prompt.ensure(project_root)
      assert.equals(1, vim.fn.filereadable(project_system_prompt.path(project_root)))
      assert.is_nil(project_system_prompt.read(project_root))
    end)

    it("does not overwrite existing content", function()
      write_prompt(project_root, "Existing rule.")
      project_system_prompt.ensure(project_root)
      assert.equals("Existing rule.", project_system_prompt.read(project_root))
    end)
  end)
end)
