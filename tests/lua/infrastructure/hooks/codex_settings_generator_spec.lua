local CodexSettingsGenerator = require("vibing.infrastructure.hooks.codex_settings_generator")
local SettingsGenerator = require("vibing.infrastructure.hooks.settings_generator")

--- @param args string[]
--- @return string|nil the `-c` value, i.e. the argument following the `-c` flag
local function config_value(args)
  for i, arg in ipairs(args) do
    if arg == "-c" then
      return args[i + 1]
    end
  end
  return nil
end

describe("codex_settings_generator", function()
  local tmp_dir
  local original_source_path
  local original_setfperm
  local original_open
  local original_lstat

  before_each(function()
    original_source_path = SettingsGenerator.get_hook_script_path
    original_setfperm = vim.fn.setfperm
    original_open = io.open
    original_lstat = vim.loop.fs_lstat
    tmp_dir = vim.fn.tempname()
    vim.fn.mkdir(tmp_dir, "p")
  end)

  after_each(function()
    SettingsGenerator.get_hook_script_path = original_source_path
    vim.fn.setfperm = original_setfperm
    io.open = original_open
    vim.loop.fs_lstat = original_lstat
    vim.fn.delete(tmp_dir, "rf")
  end)

  describe("ensure", function()
    it("stages the script inside the cwd, where codex is willing to execute it", function()
      -- Codex will not run a hook from outside the sandbox's writable roots, and it hangs the turn
      -- instead of reporting it -- so a script left in the installed plugin directory (outside the
      -- user's project by definition) makes every codex turn hang. Measured against 0.153.4: same
      -- script and argv, only the path moved, and only the in-cwd and /tmp copies ever fired.
      local path = CodexSettingsGenerator.ensure(tmp_dir)
      assert.equals(vim.fn.resolve(tmp_dir) .. "/.vibing/codex-pre-tool-use.sh", path)
      assert.equals(1, vim.fn.filereadable(path))
    end)

    it("stages it executable, or codex has nothing it can spawn", function()
      local path = CodexSettingsGenerator.ensure(tmp_dir)
      assert.equals(1, vim.fn.executable(path))
    end)

    it("copies the shared pre-tool-use.sh byte for byte", function()
      -- A copy, not a rewrite: the deny/allow/defer contract lives in that one script, and a
      -- second copy of it that drifts is a fail-closed protocol that stops failing closed.
      local staged = CodexSettingsGenerator.ensure(tmp_dir)
      local source = vim.fn.fnamemodify(SettingsGenerator.get_hook_script_path(), ":p")
      assert.equals(
        table.concat(vim.fn.readfile(source, "b"), "\n"),
        table.concat(vim.fn.readfile(staged, "b"), "\n")
      )
    end)

    it("reuses an identical 0755 copy without writing or chmod", function()
      local path = CodexSettingsGenerator.ensure(tmp_dir)
      local before = assert(vim.loop.fs_lstat(path))
      local chmod_calls = 0
      vim.fn.setfperm = function(...)
        chmod_calls = chmod_calls + 1
        return original_setfperm(...)
      end

      assert.equals(path, CodexSettingsGenerator.ensure(tmp_dir))
      local after = assert(vim.loop.fs_lstat(path))
      -- Atomic restaging replaces the inode, even when a filesystem's timestamp is too coarse.
      assert.equals(before.ino, after.ino, "an unchanged script must not be replaced")
      assert.same(before.mtime, after.mtime, "an unchanged script must not be rewritten")
      assert.equals(0, chmod_calls, "an unchanged script must not be chmodded")
    end)

    for _, mode in ipairs({ "644", "700", "775" }) do
      it("restages identical content when permissions are " .. mode, function()
        local path = CodexSettingsGenerator.ensure(tmp_dir)
        assert(vim.loop.fs_chmod(path, tonumber(mode, 8)))
        assert.equals(tonumber(mode, 8), vim.loop.fs_lstat(path).mode % 4096)
        local before = vim.loop.fs_lstat(path)

        CodexSettingsGenerator.ensure(tmp_dir)

        local after = assert(vim.loop.fs_lstat(path))
        assert.equals(tonumber("755", 8), after.mode % 4096)
        assert.are_not.equals(before.ino, after.ino, "permission repair must use atomic restaging")
      end)
    end

    it("restages identical content with special permission bits", function()
      local path = CodexSettingsGenerator.ensure(tmp_dir)
      local before = original_lstat(path)
      -- Some filesystems strip setuid on chmod. Model the observed mode at the stat boundary.
      vim.loop.fs_lstat = function(name, ...)
        local stat = original_lstat(name, ...)
        if name == path and stat then
          stat.mode = stat.mode + tonumber("4000", 8)
        end
        return stat
      end

      CodexSettingsGenerator.ensure(tmp_dir)

      local after = original_lstat(path)
      assert.equals(tonumber("755", 8), after.mode % 4096)
      assert.are_not.equals(before.ino, after.ino)
    end)

    it("replaces a matching symlink with a regular copy", function()
      local path = CodexSettingsGenerator.ensure(tmp_dir)
      local target = tmp_dir .. "/linked-hook.sh"
      vim.fn.writefile(vim.fn.readfile(path, "b"), target, "b")
      assert.equals(1, vim.fn.setfperm(target, "rwxr-xr-x"))
      assert(os.remove(path))
      assert(vim.loop.fs_symlink(target, path))

      CodexSettingsGenerator.ensure(tmp_dir)

      assert.equals("file", vim.loop.fs_lstat(path).type)
      assert.same(vim.fn.readfile(target, "b"), vim.fn.readfile(path, "b"))
    end)

    it("refreshes the copy when the source changes between calls", function()
      local source = tmp_dir .. "/source.sh"
      SettingsGenerator.get_hook_script_path = function()
        return source
      end
      vim.fn.writefile({ "#!/bin/sh", "exit 0" }, source)
      local path = CodexSettingsGenerator.ensure(tmp_dir)

      vim.fn.writefile({ "#!/bin/sh", "exit 2" }, source)
      CodexSettingsGenerator.ensure(tmp_dir)

      assert.same(vim.fn.readfile(source, "b"), vim.fn.readfile(path, "b"))
    end)

    it("does not trust an existing copy when the source disappears", function()
      CodexSettingsGenerator.ensure(tmp_dir)
      SettingsGenerator.get_hook_script_path = function()
        return tmp_dir .. "/missing-source.sh"
      end

      local ok, err = pcall(CodexSettingsGenerator.ensure, tmp_dir)
      assert.is_false(ok)
      assert.is_truthy(tostring(err):find("Failed to read the hook script", 1, true))
    end)

    it("restages when the existing copy cannot be read", function()
      local path = CodexSettingsGenerator.ensure(tmp_dir)
      local before = vim.loop.fs_lstat(path)
      io.open = function(name, mode)
        if name == path and mode == "rb" then
          return nil, "permission denied"
        end
        return original_open(name, mode)
      end

      CodexSettingsGenerator.ensure(tmp_dir)

      assert.are_not.equals(before.ino, vim.loop.fs_lstat(path).ino)
      assert.same(
        vim.fn.readfile(SettingsGenerator.get_hook_script_path(), "b"),
        vim.fn.readfile(path, "b")
      )
    end)

    it("refreshes a stale copy rather than trusting what is already there", function()
      -- The source moves when the plugin is updated or reinstalled, and a stale staged copy is a
      -- hook that silently answers with old logic.
      local path = CodexSettingsGenerator.ensure(tmp_dir)
      vim.fn.writefile({ "#!/bin/sh", "exit 0" }, path)
      CodexSettingsGenerator.ensure(tmp_dir)

      local source = vim.fn.fnamemodify(SettingsGenerator.get_hook_script_path(), ":p")
      assert.equals(
        table.concat(vim.fn.readfile(source, "b"), "\n"),
        table.concat(vim.fn.readfile(path, "b"), "\n")
      )
    end)

    it("leaves no temp file behind", function()
      CodexSettingsGenerator.ensure(tmp_dir)
      local leftovers = vim.fn.glob(tmp_dir .. "/.vibing/*.tmp", false, true)
      assert.equals(0, #leftovers, "staging must rename its temp file, not leave it")
    end)
  end)

  describe("get_hook_args", function()
    it("registers the hook under the PascalCase event key codex actually reads", function()
      -- codex 0.153 ignores `hooks.pre_tool_use` in silence: no warning, no error, and nothing in
      -- `hooks/list`. vibing.nvim shipped that spelling, so no PreToolUse hook fired on codex at
      -- all -- taking the permission gate and the git-snapshot diff baseline with it. A regression
      -- here is invisible at runtime, which is why it is asserted on the literal key.
      local value = config_value(CodexSettingsGenerator.get_hook_args(tmp_dir))
      assert.is_not_nil(value)
      assert.is_truthy(value:match("^hooks%.PreToolUse="))
      assert.is_nil(value:match("pre_tool_use="))
    end)

    it("wraps the handler in a matcher group rather than listing it at the top level", function()
      -- `[{command=...}]` parses as a matcher group with no handlers, so codex resolves zero hooks
      -- from it. The handler has to sit inside a nested `hooks=[...]` and carry its `type` tag.
      local value = config_value(CodexSettingsGenerator.get_hook_args(tmp_dir))
      assert.is_truthy(value:match('%[{hooks=%[{type="command"'))
    end)

    it("points at the staged copy, never at the installed script", function()
      local value = config_value(CodexSettingsGenerator.get_hook_args(tmp_dir))
      local staged = CodexSettingsGenerator.script_path(tmp_dir)
      assert.is_truthy(value:find(staged, 1, true), "hook command must be the staged copy")

      local source = vim.fn.fnamemodify(SettingsGenerator.get_hook_script_path(), ":p")
      assert.is_nil(value:find(source, 1, true), "pointing at the installed script hangs codex")
    end)

    it("passes the trust bypass, without which codex exec hangs on the hook", function()
      -- A registered hook is enabled but `untrusted` until reviewed in the TUI, and a
      -- `-c hooks.state.…trusted_hash` session layer does not grant trust. Headless `codex exec`
      -- then blocks on a review it cannot show. Dropping this flag while keeping the corrected key
      -- would turn every codex turn into a hang, so the two travel together.
      assert.is_truthy(
        vim.tbl_contains(
          CodexSettingsGenerator.get_hook_args(tmp_dir),
          "--dangerously-bypass-hook-trust"
        )
      )
    end)

    it("puts the derived timeout into the -c fragment, not a number of its own", function()
      -- The ordering against pre-tool-use.sh's own deadline is asserted for every backend in
      -- `hook_timeout_ordering_spec.lua`; it used to be restated here and in copilot's spec, which
      -- is how claude — covered by neither — shipped with no margin at all. What is codex-specific
      -- is that the number reaches the CLI through a `-c` TOML fragment rather than a JSON field,
      -- so that is what this checks.
      local WaitBudget = require("vibing.infrastructure.hooks.wait_budget")
      assert.equals(WaitBudget.cli_timeout_sec(), CodexSettingsGenerator.hook_timeout_sec())

      local args = CodexSettingsGenerator.get_hook_args(tmp_dir)
      assert.is_truthy(
        args[3]:find(string.format("timeout=%d}", WaitBudget.cli_timeout_sec()), 1, true),
        "the -c fragment must carry the derived timeout: " .. args[3]
      )
    end)

    it("raises rather than returning args with no script behind them", function()
      -- Registering the hook without a script codex can run is the case that *hangs* the turn,
      -- which is strictly worse than skipping the gate. So this fails loudly and `codex_cli` drops
      -- the hook; it must never come back with a `-c` pair pointing at nothing.
      SettingsGenerator.get_hook_script_path = function()
        return tmp_dir .. "/definitely-not-here.sh"
      end
      local ok, err = pcall(CodexSettingsGenerator.get_hook_args, tmp_dir)

      assert.is_false(ok)
      assert.is_truthy(tostring(err):find("hook script", 1, true))
    end)
  end)
end)
