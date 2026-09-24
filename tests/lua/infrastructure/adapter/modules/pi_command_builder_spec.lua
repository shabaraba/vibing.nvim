---@diagnostic disable: undefined-field
local Builder = require("vibing.infrastructure.adapter.modules.pi_command_builder")
local Notify = require("vibing.core.utils.notify")
local helper = require("tests.helpers.adapter_stream")

--- @param argv string[]
--- @param flag string
--- @return string|nil the token after `flag`
local function value_after(argv, flag)
  for i, token in ipairs(argv) do
    if token == flag then
      return argv[i + 1]
    end
  end
  return nil
end

--- @param argv string[]
--- @param token string
--- @return boolean
local function has(argv, token)
  return vim.tbl_contains(argv, token)
end

describe("pi_command_builder", function()
  local original_exepath
  local warnings

  before_each(function()
    original_exepath = vim.fn.exepath
    vim.fn.exepath = function()
      return helper.fake_binary("pi")
    end
    helper.reset_path_caches()
    warnings = {}
    Notify._warned = nil
    ---@diagnostic disable-next-line: duplicate-set-field
    Notify.warn_once = function(_key, message)
      table.insert(warnings, message)
    end
  end)

  after_each(function()
    vim.fn.exepath = original_exepath
    helper.reset_path_caches()
    package.loaded["vibing.core.utils.notify"] = nil
  end)

  describe("permission_args", function()
    it("gives an ordinary gated turn every tool", function()
      assert.same({}, Builder.permission_args({ opts = {}, hook_arg = "/plugin/pi-extension/dist/index.js" }))
    end)

    it("takes the writing tools away in plan mode, which pi has no concept of", function()
      -- Pi cannot be told "plan"; the only way to make the label true is to remove the tools.
      local args = Builder.permission_args({ opts = { permission_mode = "plan" }, hook_arg = "/x.js" })
      assert.same({ "--tools", "read,grep,find,ls" }, args)
    end)

    it("degrades to read-only when the permission bridge could not be installed", function()
      -- The failure this exists for: `cli_adapter` warns and carries on when a transport raises,
      -- which on every other backend still leaves the CLI's own gate in charge. Pi has none, so an
      -- ungated turn here runs bash with the user's deny rules silently inert.
      local args = Builder.permission_args({ opts = {}, hook_arg = nil })
      assert.same({ "--tools", "read,grep,find,ls" }, args)
    end)

    it("says so, rather than degrading in silence", function()
      Builder.permission_args({ opts = {}, hook_arg = nil })
      assert.equals(1, #warnings)
      assert.is_truthy(warnings[1]:lower():find("read%-only"))
    end)

    it("does not override an explicit bypassPermissions, but warns about the lost diff", function()
      -- There the user has said "do not gate me", so no configured rule is being skipped and
      -- restricting tools would be us ignoring an instruction. What is lost is the git-snapshot
      -- baseline the same round trip takes, which is what the warning has to be about.
      local args = Builder.permission_args({ opts = { permission_mode = "bypassPermissions" }, hook_arg = nil })
      assert.same({}, args)
      assert.equals(1, #warnings)
      assert.is_truthy(warnings[1]:find("Modified Files", 1, true))
    end)
  end)

  describe("session_args", function()
    it("continues a session by id", function()
      assert.same({ "--session-id", "s-1" }, Builder.session_args({ session_id = "s-1", opts = {} }))
    end)

    it("forks with --fork instead of adding a flag beside --session-id", function()
      -- Pi's fork is a different flag carrying the same id, not an extra one. Naming the session
      -- twice asks pi to both continue and fork it.
      local args = Builder.session_args({ session_id = "s-1", opts = { _is_fork = true } })
      assert.same({ "--fork", "s-1" }, args)
      assert.is_false(has(args, "--session-id"))
    end)

    it("names no session on a fresh chat", function()
      assert.same({}, Builder.session_args({ session_id = nil, opts = {} }))
      assert.same({}, Builder.session_args({ session_id = "", opts = {} }))
    end)
  end)

  describe("provider_args", function()
    it("passes a configured provider", function()
      local ctx = { config = { backends = { pi = { provider = "mlx-local" } } } }
      assert.same({ "--provider", "mlx-local" }, Builder.provider_args(ctx))
    end)

    it("lets pi choose when none is configured", function()
      assert.same({}, Builder.provider_args({ config = { backends = { pi = { provider = "" } } } }))
      assert.same({}, Builder.provider_args({ config = {} }))
    end)
  end)

  describe("the binary", function()
    it("uses a configured executable path as given, without consulting PATH", function()
      -- A user who named a path wants that binary; silently falling back to PATH runs a different
      -- one without saying so.
      local looked_up = false
      vim.fn.exepath = function()
        looked_up = true
        return "/somewhere/else/pi"
      end
      local argv = Builder.build("hi", {}, nil, { backends = { pi = { executable = "/opt/pi/bin/pi" } } }, "/x.js")
      assert.equals("/opt/pi/bin/pi", argv[1])
      assert.is_false(looked_up)
    end)
  end)

  describe("the argv", function()
    local CONFIG = { backends = { pi = { provider = "mlx-local" } } }

    it("runs pi in json mode with the prompt behind a -- terminator", function()
      local argv = Builder.build("hello", {}, nil, CONFIG, "/x.js")
      assert.equals("json", value_after(argv, "--mode"))
      assert.equals("hello", argv[#argv])
      assert.equals("--", argv[#argv - 1])
    end)

    it("names the permission bridge with --extension", function()
      local argv = Builder.build("hello", {}, nil, CONFIG, "/plugin/pi-extension/dist/index.js")
      assert.equals("/plugin/pi-extension/dist/index.js", value_after(argv, "--extension"))
    end)

    it("carries no gate flag at all on a lightweight call", function()
      -- The `core/types.lua` bargain. A utility call is fenced by --no-tools instead, and routing
      -- its tool calls into the chat's approval UI would prompt about a request nobody made.
      local argv = Builder.build("hello", { lightweight = true }, nil, CONFIG, "/x.js")
      assert.is_false(has(argv, "--extension"))
      assert.is_false(has(argv, "/x.js"))
      assert.is_true(has(argv, "--no-tools"))
    end)

    it("fences a lightweight call off from the user's project configuration", function()
      local argv = Builder.build("hello", { lightweight = true }, nil, CONFIG, nil)
      for _, flag in ipairs({ "--no-context-files", "--no-skills", "--no-extensions", "--no-approve", "--no-session" }) do
        assert.is_true(has(argv, flag), "lightweight argv is missing " .. flag)
      end
    end)

    it("does not restrict tools twice on a lightweight call", function()
      -- `permission_args` is `unless = "lightweight"`; without that the degraded read-only branch
      -- would add `--tools read,...` next to `--no-tools`, and the allowlist wins in pi.
      local argv = Builder.build("hello", { lightweight = true }, nil, CONFIG, nil)
      assert.is_false(has(argv, "--tools"))
    end)
  end)

  describe("apply_env", function()
    it("tells the bridge where the shared hook script is and when to give up", function()
      local env = {}
      Builder.apply_env(env, {})
      assert.is_truthy(env.VIBING_PI_HOOK_SCRIPT:find("pre%-tool%-use%.sh$"))
      assert.is_truthy(tonumber(env.VIBING_PI_HOOK_TIMEOUT_SEC))
    end)

    it("gives the bridge a deadline that outlasts the script's own", function()
      -- The bridge kills the script and fails closed at this number, so it has to be strictly later
      -- than the script's own expiry -- otherwise a denial the script was about to produce is
      -- replaced by a timeout that says less.
      local env = {}
      Builder.apply_env(env, {})
      local WaitBudget = require("vibing.infrastructure.hooks.wait_budget")
      assert.is_true(tonumber(env.VIBING_PI_HOOK_TIMEOUT_SEC) > WaitBudget.script_wait_sec())
    end)

    it("leaves a lightweight call's environment alone, since it registers no bridge", function()
      local env = {}
      Builder.apply_env(env, { lightweight = true })
      assert.same({}, env)
    end)
  end)
end)
