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

  before_each(function()
    tmp_dir = vim.fn.tempname()
    vim.fn.mkdir(tmp_dir, "p")
  end)

  after_each(function()
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

    it("gives codex a hook timeout that outlasts the script's own wait", function()
      -- Same invariant as copilot's generator, restated here rather than shared: whichever side
      -- gives up first decides the outcome, and only the script's deny carries a reason. Raising
      -- MAX_WAIT in pre-tool-use.sh for Claude's sake must not silently cross this number.
      local script = io.open(vim.fn.fnamemodify(SettingsGenerator.get_hook_script_path(), ":p"), "r")
      local source = script:read("*a")
      script:close()

      local max_wait_ticks = tonumber(source:match("\nMAX_WAIT=(%d+)"))
      assert.is_not_nil(max_wait_ticks, "could not read MAX_WAIT out of pre-tool-use.sh")

      local script_wait_sec = max_wait_ticks / 10 -- the poll loop sleeps 0.1s per tick
      assert.is_true(
        CodexSettingsGenerator._HOOK_TIMEOUT_SEC > script_wait_sec,
        "codex's hook timeout must outlast the script's own wait"
      )
    end)

    it("raises rather than returning args with no script behind them", function()
      -- Registering the hook without a script codex can run is the case that *hangs* the turn,
      -- which is strictly worse than skipping the gate. So this fails loudly and `codex_cli` drops
      -- the hook; it must never come back with a `-c` pair pointing at nothing.
      local original = SettingsGenerator.get_hook_script_path
      SettingsGenerator.get_hook_script_path = function()
        return tmp_dir .. "/definitely-not-here.sh"
      end
      local ok, err = pcall(CodexSettingsGenerator.get_hook_args, tmp_dir)
      SettingsGenerator.get_hook_script_path = original

      assert.is_false(ok)
      assert.is_truthy(tostring(err):find("hook script", 1, true))
    end)
  end)
end)
