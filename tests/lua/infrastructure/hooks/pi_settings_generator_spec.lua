---@diagnostic disable: undefined-field
local Generator = require("vibing.infrastructure.hooks.pi_settings_generator")
local Transports = require("vibing.infrastructure.hooks.transports")
local WaitBudget = require("vibing.infrastructure.hooks.wait_budget")

describe("pi_settings_generator", function()
  describe("bundle_path", function()
    it("points at the built extension inside the plugin checkout", function()
      local path = Generator.bundle_path()
      assert.is_truthy(path:find("/pi%-extension/dist/index%.js$"))
      assert.equals("/", path:sub(1, 1))
    end)

    it("resolves next to the plugin's own bin/hooks, not relative to the cwd", function()
      -- The other transports write into the cwd; this one resolves a shipped artifact, so it has
      -- to come out of the module's own location. A cwd-relative answer would find nothing
      -- whenever a chat has a `working_dir`.
      local SettingsGenerator = require("vibing.infrastructure.hooks.settings_generator")
      local plugin_root = vim.fn.fnamemodify(SettingsGenerator.get_hook_script_path(), ":h:h:h")
      assert.equals(plugin_root .. "/pi-extension/dist/index.js", Generator.bundle_path())
    end)
  end)

  describe("ensure", function()
    it("returns the bundle path when it is built", function()
      local path = Generator.bundle_path()
      if vim.fn.filereadable(path) == 0 then
        -- The bundle is git-ignored, exactly as the MCP server's dist/ is, so a fresh checkout that
        -- has not run ./build.sh has nothing to assert against here. The raising case below is the
        -- one that matters and it is covered unconditionally.
        return
      end
      assert.equals(path, Generator.ensure("/tmp", "claude"))
    end)

    it("raises when the bundle is missing, naming build.sh and why it matters", function()
      local original = vim.fn.filereadable
      ---@diagnostic disable-next-line: duplicate-set-field
      vim.fn.filereadable = function()
        return 0
      end
      local ok, err = pcall(Generator.ensure, "/tmp", "claude")
      vim.fn.filereadable = original

      assert.is_false(ok)
      assert.is_truthy(tostring(err):find("build.sh", 1, true))
      -- The message has to say what is lost, not just what is missing: the whole point is that Pi
      -- has no gate of its own, and a bare "file not found" reads as cosmetic.
      assert.is_truthy(tostring(err):lower():find("permission gate", 1, true))
    end)

    it("writes nothing, unlike every other transport", function()
      -- The deadline travels in the child's environment rather than in a generated file, which is
      -- what makes the per-instance keying the others need unnecessary here. A file appearing under
      -- .vibing/ would reintroduce the sharing hazard silently.
      local tmp = vim.fn.tempname()
      vim.fn.mkdir(tmp, "p") -- mkdir-ok: a spec-local path under vim.fn.tempname()
      pcall(Generator.ensure, tmp, "claude")
      assert.same({}, vim.fn.readdir(tmp))
    end)
  end)

  describe("hook_timeout_sec", function()
    it("reports a number, so the fail-open ordering can be checked for pi at all", function()
      -- `hook_timeout_ordering_spec` refuses a transport that answers nil: "no timeout" and "a
      -- schema this check cannot see into" are indistinguishable from outside.
      assert.is_number(Generator.hook_timeout_sec())
      assert.is_number(Transports.hook_timeout_sec({ transport = "extension_file" }))
    end)

    it("is the deadline the extension itself enforces, from the shared derivation", function()
      -- Pi applies no timeout to an extension handler, so unlike the other four this is not a
      -- number a CLI was configured with. It is what `pi_command_builder.apply_env` puts in
      -- VIBING_PI_HOOK_TIMEOUT_SEC, and both come from wait_budget so they cannot drift.
      assert.equals(WaitBudget.cli_timeout_sec(), Generator.hook_timeout_sec())
    end)
  end)

  describe("the transport registration", function()
    it("is reachable by name from a descriptor", function()
      assert.is_true(vim.tbl_contains(Transports.NAMES, "extension_file"))
    end)

    it("speaks the claude dialect, because the bridge reads the script's exit code", function()
      -- Not a new dialect: the extension spawns bin/hooks/pre-tool-use.sh and interprets exit 2 /
      -- exit 0 exactly as claude's branch describes. A pi dialect would be a second spelling of a
      -- decision the script already phrases.
      local descriptor = require("vibing.infrastructure.adapter.backends.pi")
      assert.equals("claude", descriptor.hook.dialect)
      assert.is_true(Transports.DIALECTS[descriptor.hook.dialect])
    end)

    it("keeps the hook in bypassPermissions, for the diff baseline", function()
      -- bypassPermissions bypasses the decision, not the git-snapshot baseline the same round trip
      -- takes. Dropping it costs ### Modified Files, .vibing/patches/*.patch and `gd`.
      local descriptor = require("vibing.infrastructure.adapter.backends.pi")
      assert.is_true(Transports.wanted(descriptor.hook, { permission_mode = "bypassPermissions" }))
    end)

    it("registers no hook for a lightweight call", function()
      local descriptor = require("vibing.infrastructure.adapter.backends.pi")
      assert.is_false(Transports.wanted(descriptor.hook, { lightweight = true }))
    end)
  end)
end)
