local notice = require("vibing.infrastructure.adapter.modules.codex_provider_notice")

describe("codex_provider_notice", function()
  local original_system, original_notify
  local spawned, notified

  before_each(function()
    notice._reset()
    spawned, notified = {}, {}

    original_system = vim.system
    original_notify = vim.notify

    vim.notify = function(msg, level)
      table.insert(notified, { msg = msg, level = level })
    end
  end)

  after_each(function()
    -- The warning is scheduled, so a test that did not wait for it would otherwise leak its
    -- notification into the next test's list.
    vim.wait(50)
    vim.system = original_system
    vim.notify = original_notify
  end)

  --- Replace vim.system with a recorder that hands `stdout` straight to the callback.
  local function stub_system(stdout)
    vim.system = function(cmd, opts, on_exit)
      table.insert(spawned, { cmd = cmd, opts = opts })
      on_exit({ code = 1, stdout = stdout, stderr = "" })
      return { pid = 1 }
    end
  end

  --- The warning is emitted from inside vim.schedule, so drain the scheduler before asserting.
  local function drain()
    vim.wait(200, function()
      return #notified > 0
    end, 10)
  end

  describe("parse_provider", function()
    --- Captured from codex 0.147 (`codex doctor --json` with a custom provider in config.toml),
    --- then trimmed to the checks this module reads and stripped of machine-specific paths. The
    --- point of pinning it is the key name: `"model provider"`, with a space, not `model_provider`.
    local function real_report()
      local path = vim.fn.getcwd() .. "/tests/fixtures/codex_doctor.json"
      return table.concat(vim.fn.readfile(path), "\n")
    end

    it("reads the resolved provider out of a real doctor report", function()
      assert.are.equal("myprov", notice.parse_provider(real_report()))
    end)

    it("ignores a report whose config check did not succeed", function()
      local report = vim.json.decode(real_report())
      report.checks["config.load"].status = "fail"
      assert.is_nil(notice.parse_provider(vim.json.encode(report)))
    end)

    it("returns nil when the provider key is renamed", function()
      local report = vim.json.decode(real_report())
      report.checks["config.load"].details["model provider"] = nil
      report.checks["config.load"].details["model_provider"] = "myprov"
      assert.is_nil(notice.parse_provider(vim.json.encode(report)))
    end)

    it("returns nil for output that is not a doctor report", function()
      assert.is_nil(notice.parse_provider(nil))
      assert.is_nil(notice.parse_provider(""))
      assert.is_nil(notice.parse_provider("not json at all"))
      assert.is_nil(notice.parse_provider("[]"))
      assert.is_nil(notice.parse_provider('{"checks":{}}'))
      assert.is_nil(notice.parse_provider('{"checks":{"config.load":{"status":"ok"}}}'))
    end)
  end)

  describe("check", function()
    local function report_with(provider)
      return vim.json.encode({
        checks = { ["config.load"] = { status = "ok", details = { ["model provider"] = provider } } },
      })
    end

    it("warns once, naming the configured provider", function()
      stub_system(report_with("myprov"))
      notice.check("/usr/local/bin/codex")
      drain()

      assert.are.equal(1, #notified)
      assert.are.equal(vim.log.levels.WARN, notified[1].level)
      assert.is_truthy(notified[1].msg:find("myprov", 1, true))
      assert.is_truthy(notified[1].msg:find("openai", 1, true))
    end)

    -- %q would render this as `\"weird\"` plus a Lua escape for the newline. The name comes
    -- straight from the user's config.toml, so it is only ever displayed, never re-parsed.
    it("shows an awkward provider name as written, without Lua escapes", function()
      stub_system(report_with('we"ird\nname'))
      notice.check("/usr/local/bin/codex")
      drain()

      assert.is_truthy(notified[1].msg:find('we"ird\nname', 1, true))
      assert.is_nil(notified[1].msg:find("\\", 1, true))
    end)

    it("asks codex to resolve the provider rather than reading config.toml", function()
      stub_system(report_with("myprov"))
      notice.check("/usr/local/bin/codex", "/tmp/some-worktree")

      assert.are.same({ "/usr/local/bin/codex", "doctor", "--json" }, spawned[1].cmd)
      -- Same directory as the call being described, so the two cannot resolve different configs.
      assert.are.equal("/tmp/some-worktree", spawned[1].opts.cwd)
      assert.is_truthy(spawned[1].opts.timeout)
    end)

    it("probes at most once per session, however many lightweight calls run", function()
      stub_system(report_with("myprov"))
      notice.check("/usr/local/bin/codex")
      notice.check("/usr/local/bin/codex")
      notice.check("/usr/local/bin/codex")
      drain()

      assert.are.equal(1, #spawned)
      assert.are.equal(1, #notified)
    end)

    it("stays quiet when nothing is being taken away", function()
      stub_system(report_with("openai"))
      notice.check("/usr/local/bin/codex")
      vim.wait(50)
      assert.are.equal(0, #notified)
    end)

    it("stays quiet rather than guessing when the report is unreadable", function()
      stub_system("codex: unknown subcommand 'doctor'")
      notice.check("/usr/local/bin/codex")
      vim.wait(50)
      assert.are.equal(0, #notified)
    end)

    it("survives a codex that cannot be spawned", function()
      vim.system = function()
        error("ENOENT")
      end
      assert.has_no.errors(function()
        notice.check("/usr/local/bin/codex")
      end)
      assert.are.equal(0, #notified)
    end)
  end)
end)
