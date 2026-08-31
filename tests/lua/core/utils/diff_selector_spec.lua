local DiffSelector = require("vibing.core.utils.diff_selector")

describe("diff_selector", function()
  describe("_show_git_diff", function()
    local repo_dir
    local notify_messages
    local original_notify

    local function write_file(path, content)
      local f = assert(io.open(path, "w"))
      f:write(content)
      f:close()
    end

    local function git(args)
      local cmd = { "git" }
      vim.list_extend(cmd, args)
      local result = vim.system(cmd, { cwd = repo_dir, text = true }):wait()
      assert.equals(0, result.code, result.stderr)
    end

    ---現在のウィンドウに表示されたdiffバッファの内容を返す
    local function current_diff_buffer_text()
      local buf = vim.api.nvim_get_current_buf()
      if vim.bo[buf].filetype ~= "diff" then
        return nil
      end
      return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
    end

    before_each(function()
      repo_dir = vim.fn.tempname()
      vim.fn.mkdir(repo_dir, "p")
      repo_dir = vim.fn.fnamemodify(repo_dir, ":p"):gsub("/$", "")
      git({ "init", "-q" })
      git({ "config", "user.email", "test@example.com" })
      git({ "config", "user.name", "test" })

      notify_messages = {}
      original_notify = vim.notify
      vim.notify = function(msg, level)
        table.insert(notify_messages, { msg = msg, level = level })
      end
    end)

    after_each(function()
      vim.notify = original_notify
      vim.cmd("only")
      vim.fn.delete(repo_dir, "rf")
    end)

    it("shows HEAD diff for a tracked modified file", function()
      local file = repo_dir .. "/tracked.txt"
      write_file(file, "before\n")
      git({ "add", "." })
      git({ "commit", "-q", "-m", "init" })
      write_file(file, "after\n")

      DiffSelector._show_git_diff(file)

      local text = current_diff_buffer_text()
      assert.is_truthy(text)
      assert.is_truthy(text:find("-before", 1, true))
      assert.is_truthy(text:find("+after", 1, true))
    end)

    it("shows the whole file as new for an untracked file", function()
      local file = repo_dir .. "/untracked.txt"
      write_file(file, "brand new\n")

      DiffSelector._show_git_diff(file)

      local text = current_diff_buffer_text()
      assert.is_truthy(text)
      assert.is_truthy(text:find("+brand new", 1, true))
      assert.is_truthy(text:find("/dev/null", 1, true))
    end)

    it("falls back to the index diff for a staged file before the first commit", function()
      local file = repo_dir .. "/staged.txt"
      write_file(file, "staged content\n")
      git({ "add", "." })

      DiffSelector._show_git_diff(file)

      local text = current_diff_buffer_text()
      assert.is_truthy(text)
      assert.is_truthy(text:find("+staged content", 1, true))
    end)

    it("notifies instead of opening a window when there are no changes", function()
      local file = repo_dir .. "/clean.txt"
      write_file(file, "committed\n")
      git({ "add", "." })
      git({ "commit", "-q", "-m", "init" })

      local win_count_before = #vim.api.nvim_list_wins()
      DiffSelector._show_git_diff(file)

      assert.equals(win_count_before, #vim.api.nvim_list_wins())
      assert.equals(1, #notify_messages)
      assert.is_truthy(notify_messages[1].msg:find("No changes to show", 1, true))
    end)
  end)
end)
