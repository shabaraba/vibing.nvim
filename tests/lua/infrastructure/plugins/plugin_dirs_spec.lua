local PluginDirs = require("vibing.infrastructure.plugins.plugin_dirs")

describe("plugin_dirs", function()
  local project_root
  local original_getcwd
  local original_notify
  local notifications

  ---Create a plugin directory with a manifest declaring `name`.
  ---@param dir string
  ---@param name string
  local function write_plugin(dir, name)
    vim.fn.mkdir(dir .. "/.claude-plugin", "p")
    vim.fn.writefile({ vim.json.encode({ name = name }) }, dir .. "/.claude-plugin/plugin.json")
  end

  ---The repo's own claude-plugin/, which `self` resolves to.
  local function own_plugin_dir()
    local root = vim.fs.root(debug.getinfo(1, "S").source:sub(2), "package.json")
    return root .. "/claude-plugin"
  end

  before_each(function()
    PluginDirs.clear_cache()
    project_root = vim.fn.tempname()
    vim.fn.mkdir(project_root, "p")
    original_getcwd = vim.fn.getcwd
    vim.fn.getcwd = function()
      return project_root
    end
    notifications = {}
    original_notify = vim.notify
    vim.notify = function(msg, level)
      table.insert(notifications, { msg = msg, level = level })
    end
  end)

  after_each(function()
    vim.notify = original_notify
    vim.fn.getcwd = original_getcwd
    vim.fn.delete(project_root, "rf")
    PluginDirs.clear_cache()
  end)

  describe("self", function()
    it("resolves vibing.nvim's own claude-plugin/ by default", function()
      local dirs = PluginDirs.resolve(nil, {})
      assert.same({ own_plugin_dir() }, dirs)
    end)

    it("reports it under the name declared in its manifest, not its directory name", function()
      local entries = PluginDirs.resolve_entries(nil, {})
      assert.equals("vibing-nvim", entries[1].name)
    end)

    it("is omitted when agent.plugins.self is false", function()
      local dirs = PluginDirs.resolve(nil, { agent = { plugins = { self = false } } })
      assert.same({}, dirs)
    end)
  end)

  describe("project_dir", function()
    local config = { agent = { plugins = { project_dir = ".vibing/plugins" } } }

    it("picks up every directory under it that carries a manifest", function()
      write_plugin(project_root .. "/.vibing/plugins/alpha", "alpha")
      write_plugin(project_root .. "/.vibing/plugins/beta", "beta")

      local dirs = PluginDirs.resolve(nil, config)

      assert.equals(3, #dirs)
      assert.equals(own_plugin_dir(), dirs[1])
      assert.equals(project_root .. "/.vibing/plugins/alpha", dirs[2])
      assert.equals(project_root .. "/.vibing/plugins/beta", dirs[3])
    end)

    it("adds nothing when the directory does not exist", function()
      assert.same({ own_plugin_dir() }, PluginDirs.resolve(nil, config))
    end)

    it("is skipped entirely when set to false", function()
      write_plugin(project_root .. "/.vibing/plugins/alpha", "alpha")
      local dirs = PluginDirs.resolve(nil, { agent = { plugins = { project_dir = false } } })
      assert.same({ own_plugin_dir() }, dirs)
    end)
  end)

  describe("broken candidates", function()
    local config = { agent = { plugins = { project_dir = ".vibing/plugins" } } }

    -- `--plugin-dir` ignores these without a word (measured on claude 2.1.231: exit 0, no
    -- warning, turn completes), so "I dropped a plugin in and nothing happened" would otherwise
    -- have no explanation anywhere.
    it("drops a directory with no manifest and says so", function()
      vim.fn.mkdir(project_root .. "/.vibing/plugins/nomanifest", "p")

      local dirs = PluginDirs.resolve(nil, config)

      assert.same({ own_plugin_dir() }, dirs)
      assert.equals(1, #notifications)
      assert.is_true(notifications[1].msg:find("nomanifest", 1, true) ~= nil)
      assert.equals(vim.log.levels.WARN, notifications[1].level)
    end)

    it("drops a directory whose manifest is not valid JSON", function()
      vim.fn.mkdir(project_root .. "/.vibing/plugins/broken/.claude-plugin", "p")
      vim.fn.writefile({ "{ not json" }, project_root .. "/.vibing/plugins/broken/.claude-plugin/plugin.json")

      assert.same({ own_plugin_dir() }, PluginDirs.resolve(nil, config))
      assert.equals(1, #notifications)
      assert.is_true(notifications[1].msg:find("malformed", 1, true) ~= nil)
    end)

    it("drops a manifest with no name", function()
      vim.fn.mkdir(project_root .. "/.vibing/plugins/anon/.claude-plugin", "p")
      vim.fn.writefile(
        { vim.json.encode({ description = "no name here" }) },
        project_root .. "/.vibing/plugins/anon/.claude-plugin/plugin.json"
      )

      assert.same({ own_plugin_dir() }, PluginDirs.resolve(nil, config))
      assert.equals(1, #notifications)
    end)

    -- Resolution happens on every request, so a per-call warning would notify on every message.
    it("warns once per cwd, not once per call", function()
      vim.fn.mkdir(project_root .. "/.vibing/plugins/nomanifest", "p")

      PluginDirs.resolve(nil, config)
      PluginDirs.resolve(nil, config)
      PluginDirs.resolve(nil, config)

      assert.equals(1, #notifications)
    end)

    -- An explicit reload is the user saying "I changed something, look again" -- typically right
    -- after trying to fix the manifest. Staying quiet there would report a still-broken plugin
    -- as fixed.
    it("warns again after an explicit cache clear", function()
      vim.fn.mkdir(project_root .. "/.vibing/plugins/nomanifest", "p")

      PluginDirs.resolve(nil, config)
      PluginDirs.clear_cache()
      PluginDirs.resolve(nil, config)

      assert.equals(2, #notifications)
    end)
  end)

  describe("caching", function()
    local config = { agent = { plugins = { project_dir = ".vibing/plugins" } } }

    it("does not re-scan until the cache is cleared", function()
      assert.same({ own_plugin_dir() }, PluginDirs.resolve(nil, config))

      write_plugin(project_root .. "/.vibing/plugins/late", "late")
      assert.same({ own_plugin_dir() }, PluginDirs.resolve(nil, config))

      PluginDirs.clear_cache()
      assert.equals(2, #PluginDirs.resolve(nil, config))
    end)

    it("keys on the request's cwd, so a worktree does not read the root's cached list", function()
      local worktree = project_root .. "/.vibing/worktrees/feature"
      write_plugin(worktree .. "/.vibing/plugins/only-here", "only-here")

      assert.same({ own_plugin_dir() }, PluginDirs.resolve(nil, config))

      local from_worktree = PluginDirs.resolve(worktree, config)
      assert.equals(2, #from_worktree)
      assert.equals(worktree .. "/.vibing/plugins/only-here", from_worktree[2])
    end)
  end)

  describe("worktree fallback", function()
    local config = { agent = { plugins = { project_dir = ".vibing/plugins" } } }

    -- `.vibing/` is git-ignored, so a worktree checkout starts with no `.vibing/plugins` of its
    -- own. Without the fallback, moving a chat into a worktree would silently drop every
    -- project plugin the user had set up.
    it("falls back to the Neovim root when the worktree has no plugins of its own", function()
      write_plugin(project_root .. "/.vibing/plugins/shared", "shared")
      local worktree = project_root .. "/.vibing/worktrees/feature"
      vim.fn.mkdir(worktree, "p")

      local dirs = PluginDirs.resolve(worktree, config)

      assert.equals(2, #dirs)
      assert.equals(project_root .. "/.vibing/plugins/shared", dirs[2])
    end)

    -- Deliberately a union, not the strict fallback `.vibing/system-prompt.md` gets: a worktree
    -- that adds one plugin should not lose the ones the project already had.
    it("keeps both when the worktree and the root declare different plugins", function()
      write_plugin(project_root .. "/.vibing/plugins/from-root", "from-root")
      local worktree = project_root .. "/.vibing/worktrees/feature"
      write_plugin(worktree .. "/.vibing/plugins/from-worktree", "from-worktree")

      local dirs = PluginDirs.resolve(worktree, config)

      assert.equals(3, #dirs)
      assert.equals(worktree .. "/.vibing/plugins/from-worktree", dirs[2])
      assert.equals(project_root .. "/.vibing/plugins/from-root", dirs[3])
    end)

    it("prefers the worktree's own copy when both declare the same plugin name", function()
      write_plugin(project_root .. "/.vibing/plugins/shared", "shared")
      local worktree = project_root .. "/.vibing/worktrees/feature"
      write_plugin(worktree .. "/.vibing/plugins/shared", "shared")

      local dirs = PluginDirs.resolve(worktree, config)

      assert.equals(2, #dirs)
      assert.equals(worktree .. "/.vibing/plugins/shared", dirs[2])
    end)
  end)

  describe("extra", function()
    it("accepts an absolute path", function()
      local elsewhere = vim.fn.tempname()
      write_plugin(elsewhere, "elsewhere")

      local dirs = PluginDirs.resolve(nil, { agent = { plugins = { extra = { elsewhere } } } })

      assert.same({ own_plugin_dir(), elsewhere }, dirs)
      vim.fn.delete(elsewhere, "rf")
    end)

    it("resolves a relative path against the request's cwd", function()
      write_plugin(project_root .. "/tools/my-plugin", "my-plugin")

      local dirs = PluginDirs.resolve(nil, { agent = { plugins = { extra = { "tools/my-plugin" } } } })

      assert.same({ own_plugin_dir(), project_root .. "/tools/my-plugin" }, dirs)
    end)
  end)

  -- The CLI resolves a duplicate plugin name in favour of the earlier --plugin-dir (measured on
  -- claude 2.1.231 by giving two same-named copies of a skill different marker words and reading
  -- back which one the model saw). Deduplicating the same way means the returned list is what
  -- actually loads, and that a project plugin cannot shadow vibing.nvim's own by taking its name.
  describe("underscore-prefixed directories", function()
    it("are not loaded, which is what parks a plugin without deleting it", function()
      write_plugin(project_root .. "/.vibing/plugins/_template", "template")
      write_plugin(project_root .. "/.vibing/plugins/live", "live")

      local dirs = PluginDirs.resolve(nil, {
        agent = { plugins = { self = false, project_dir = ".vibing/plugins" } },
      })

      assert.same({ project_root .. "/.vibing/plugins/live" }, dirs)
    end)

    it("are skipped silently, since they are parked on purpose", function()
      vim.fn.mkdir(project_root .. "/.vibing/plugins/_broken", "p")

      PluginDirs.resolve(nil, {
        agent = { plugins = { self = false, project_dir = ".vibing/plugins" } },
      })

      assert.same({}, notifications)
    end)
  end)

  describe("malformed config", function()
    -- `candidates()` indexes `plugins.self`, so a truthy non-table raised. The builder runs under
    -- pcall, which turned a config typo into an unexplained "failed to build command".
    it("treats a non-table agent.plugins as unset instead of raising", function()
      for _, bad in ipairs({ true, "yes", 42 }) do
        local ok, dirs = pcall(PluginDirs.resolve, nil, { agent = { plugins = bad } })
        PluginDirs.clear_cache()
        assert.is_true(ok, vim.inspect(bad))
        assert.same({ own_plugin_dir() }, dirs)
      end
    end)
  end)

  describe("duplicate plugin names", function()
    it("keeps the first and drops the rest", function()
      write_plugin(project_root .. "/.vibing/plugins/impostor", "vibing-nvim")

      local dirs = PluginDirs.resolve(nil, { agent = { plugins = { project_dir = ".vibing/plugins" } } })

      assert.same({ own_plugin_dir() }, dirs)
    end)
  end)
end)
