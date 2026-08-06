local DiffSelector = require("vibing.core.utils.diff_selector")

describe("diff_selector", function()
  describe("_find_mote_dir", function()
    it("returns the mote_dir containing the file", function()
      local dir = DiffSelector._find_mote_dir("/repo/workspaces/app/src/main.lua", {
        "/repo/workspaces/other",
        "/repo/workspaces/app",
      })
      assert.equals("/repo/workspaces/app", dir)
    end)

    it("returns nil when no mote_dir contains the file", function()
      assert.is_nil(DiffSelector._find_mote_dir("/elsewhere/file.lua", { "/repo/workspaces/app" }))
    end)

    it("returns nil for empty or missing mote_dirs", function()
      assert.is_nil(DiffSelector._find_mote_dir("/repo/file.lua", {}))
      assert.is_nil(DiffSelector._find_mote_dir("/repo/file.lua", nil))
    end)

    it("does not match a path prefix that is not a directory boundary", function()
      assert.is_nil(DiffSelector._find_mote_dir("/repo/workspaces/app-extra/file.lua", { "/repo/workspaces/app" }))
    end)

    it("does not match the mote_dir itself (files only, by design)", function()
      assert.is_nil(DiffSelector._find_mote_dir("/repo/workspaces/app", { "/repo/workspaces/app" }))
    end)

    it("normalizes trailing slashes on mote_dirs", function()
      local dir = DiffSelector._find_mote_dir("/repo/workspaces/app/file.lua", { "/repo/workspaces/app/" })
      assert.equals("/repo/workspaces/app", dir)
    end)

    it("prefers the deepest matching mote_dir when dirs are nested", function()
      local dir = DiffSelector._find_mote_dir("/repo/a/b/file.lua", { "/repo/a", "/repo/a/b" })
      assert.equals("/repo/a/b", dir)

      -- 登録順に依存しないこと
      dir = DiffSelector._find_mote_dir("/repo/a/b/file.lua", { "/repo/a/b", "/repo/a" })
      assert.equals("/repo/a/b", dir)
    end)
  end)

  describe("show_diff mote context selection", function()
    local Config = require("vibing.config")
    local original_get
    local original_mote_diff
    local captured

    ---MoteDiffをスタブし、show_diffに渡されたconfigをキャプチャする
    local function stub_mote_diff()
      captured = {}
      original_mote_diff = package.loaded["vibing.core.utils.mote_diff"]
      package.loaded["vibing.core.utils.mote_diff"] = {
        get_project_name = function()
          return "test-project"
        end,
        build_context_name = function(prefix, cwd)
          return prefix .. "-session-context"
        end,
        build_context_name_from_path = function(prefix, path)
          return prefix .. "-dir-context"
        end,
        show_diff = function(_, mote_config)
          captured.mote_config = mote_config
        end,
      }
    end

    local function stub_config(tool)
      original_get = Config.get
      Config.get = function()
        return { diff = { tool = tool, mote = { context_prefix = "vibing" } } }
      end
    end

    after_each(function()
      if original_get then
        Config.get = original_get
        original_get = nil
      end
      if original_mote_diff ~= nil then
        package.loaded["vibing.core.utils.mote_diff"] = original_mote_diff
        original_mote_diff = nil
      end
    end)

    it("uses the per-dir context when the file is under a mote_dir, even with tool = mote", function()
      -- 送信時（_create_session_mote_configs）はmote_dirs優先でディレクトリ単位コンテキストに
      -- スナップショットを書くため、tool = "mote" 併用時も表示側は同じコンテキストを使うこと
      stub_config("mote")
      stub_mote_diff()

      DiffSelector.show_diff("/repo/workspaces/app/src/x.lua", nil, "/repo", { "/repo/workspaces/app" })

      assert.equals("vibing-dir-context", captured.mote_config.context)
      assert.equals("/repo/workspaces/app", captured.mote_config.cwd)
    end)

    it("uses the session-cwd context with tool = mote and no matching mote_dir", function()
      stub_config("mote")
      stub_mote_diff()

      DiffSelector.show_diff("/repo/src/x.lua", nil, "/repo", nil)

      assert.equals("vibing-session-context", captured.mote_config.context)
    end)

    it("uses the per-dir context when a mote_dir matches under tool = auto", function()
      stub_config("auto")
      stub_mote_diff()

      DiffSelector.show_diff("/repo/workspaces/app/src/x.lua", nil, "/repo", { "/repo/workspaces/app" })

      assert.equals("vibing-dir-context", captured.mote_config.context)
      assert.equals("/repo/workspaces/app", captured.mote_config.cwd)
    end)
  end)

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
