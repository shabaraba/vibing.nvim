---@diagnostic disable: undefined-field
--- The argv engine behind every descriptor's `request` (ADR 009 P2). The per-backend argv is pinned
--- by each builder's own spec; this covers the primitives and the value resolution they share.
local RequestBuilder = require("vibing.infrastructure.adapter.modules.request_builder")
local helper = require("tests.helpers.adapter_stream")

describe("request_builder", function()
  local binary

  before_each(function()
    binary = { resolve = function()
      return "/bin/fake-cli"
    end, reset = function() end }
  end)

  local function build(parts, prompt, opts, session_id, config, hook_arg)
    return RequestBuilder.build({ binary = binary, parts = parts }, prompt or "hi", opts or {}, session_id, config or {}, hook_arg)
  end

  it("starts with the binary and applies the parts in the order given", function()
    local cmd = build({
      { kind = "args", "a", "b" },
      { kind = "prompt" },
      { kind = "args", "z" },
    })
    assert.same({ "/bin/fake-cli", "a", "b", "hi", "z" }, cmd)
  end)

  describe("conditions", function()
    it("honours when and unless for the named predicates", function()
      local parts = {
        { kind = "args", "L", when = "lightweight" },
        { kind = "args", "N", unless = "lightweight" },
        { kind = "args", "S", when = "session" },
        { kind = "args", "H", when = "hook_arg" },
      }
      assert.same({ "/bin/fake-cli", "N" }, build(parts))
      assert.same({ "/bin/fake-cli", "L", "S", "H" }, build(parts, "hi", { lightweight = true }, "sess", {}, "/hook"))
    end)

    it("reads a config path as a condition", function()
      local parts = { { kind = "args", "F", when = { config = "agent.subagent.enabled" } } }
      assert.same({ "/bin/fake-cli" }, build(parts))
      assert.same({ "/bin/fake-cli", "F" }, build(parts, "hi", {}, nil, { agent = { subagent = { enabled = true } } }))
    end)

    it("requires every when and rejects on any unless", function()
      local parts = { { kind = "args", "X", when = { "session", "hook_arg" }, unless = "lightweight" } }
      assert.same({ "/bin/fake-cli" }, build(parts, "hi", {}, "sess"))
      assert.same({ "/bin/fake-cli", "X" }, build(parts, "hi", {}, "sess", {}, "h"))
      assert.same({ "/bin/fake-cli" }, build(parts, "hi", { lightweight = true }, "sess", {}, "h"))
    end)

    it("refuses a condition it does not know rather than silently skipping the part", function()
      assert.has_error(function()
        build({ { kind = "args", "X", when = "sometimes" } })
      end)
    end)
  end)

  describe("model", function()
    it("passes claude's short names through and prefers utility_model on a lightweight call", function()
      local part = { kind = "model", flag = "--model", names = "claude" }
      local config = { agent = { default_model = "opus", utility_model = "haiku" } }
      assert.same({ "/bin/fake-cli", "--model", "sonnet" }, build({ part }, "hi", { model = "sonnet" }, nil, config))
      assert.same({ "/bin/fake-cli", "--model", "opus" }, build({ part }, "hi", {}, nil, config))
      assert.same({ "/bin/fake-cli", "--model", "haiku" }, build({ part }, "hi", { lightweight = true, model = "opus" }, nil, config))
      assert.same({ "/bin/fake-cli", "--model", "sonnet" }, build({ part }, "hi", { lightweight = true }, nil, {}))
    end)

    it("drops claude's short names for a native backend", function()
      local part = { kind = "model", flag = "-m", names = "native" }
      assert.same({ "/bin/fake-cli" }, build({ part }, "hi", { model = "sonnet" }))
      assert.same({ "/bin/fake-cli", "-m", "gpt-5.5" }, build({ part }, "hi", { model = "gpt-5.5" }))
    end)
  end)

  describe("effort", function()
    it("emits a flag or a -c override, and nothing for default", function()
      assert.same({ "/bin/fake-cli", "--effort", "high" }, build({ { kind = "effort", flag = "--effort" } }, "hi", { effort = "high" }))
      assert.same(
        { "/bin/fake-cli", "-c", 'model_reasoning_effort="low"' },
        build({ { kind = "effort", config = 'model_reasoning_effort="%s"' } }, "hi", { effort = "low" })
      )
      assert.same({ "/bin/fake-cli" }, build({ { kind = "effort", flag = "--effort" } }, "hi", { effort = "default" }))
    end)
  end)

  describe("resume", function()
    it("spells a resume as a flag, a flag=value or a subcommand, with the fork flag when asked", function()
      assert.same({ "/bin/fake-cli" }, build({ { kind = "resume", flag = "--resume" } }))
      assert.same({ "/bin/fake-cli", "--resume", "s1" }, build({ { kind = "resume", flag = "--resume", fork = "--fork-session" } }, "hi", {}, "s1"))
      assert.same(
        { "/bin/fake-cli", "--resume", "s1", "--fork-session" },
        build({ { kind = "resume", flag = "--resume", fork = "--fork-session" } }, "hi", { _is_fork = true }, "s1")
      )
      assert.same({ "/bin/fake-cli", "--resume=s1" }, build({ { kind = "resume", flag_eq = "--resume=" } }, "hi", {}, "s1"))
      assert.same({ "/bin/fake-cli", "resume", "s1" }, build({ { kind = "resume", subcommand = "resume" } }, "hi", {}, "s1"))
    end)
  end)

  describe("hook_arg", function()
    it("places a path behind its flag and a fragment verbatim, and nothing when no hook was installed", function()
      assert.same({ "/bin/fake-cli" }, build({ { kind = "hook_arg", flag = "--settings" } }))
      assert.same({ "/bin/fake-cli", "--settings", "/s.json" }, build({ { kind = "hook_arg", flag = "--settings" } }, "hi", {}, nil, {}, "/s.json"))
      assert.same({ "/bin/fake-cli", "-c", "hooks=x" }, build({ { kind = "hook_arg" } }, "hi", {}, nil, {}, { "-c", "hooks=x" }))
    end)
  end)

  describe("permission_mode", function()
    it("passes the mode through a translation table", function()
      local part = { kind = "permission_mode", flag = "--permission-mode", map = { auto = "default" } }
      assert.same({ "/bin/fake-cli" }, build({ part }))
      assert.same({ "/bin/fake-cli", "--permission-mode", "plan" }, build({ part }, "hi", { permission_mode = "plan" }))
      assert.same({ "/bin/fake-cli", "--permission-mode", "default" }, build({ part }, "hi", { permission_mode = "auto" }))
    end)
  end)

  describe("prompt", function()
    it("prefixes the context on a new session only", function()
      local opts = { context = { "@file:a.lua" } }
      assert.same({ "/bin/fake-cli", "Context file: a.lua\n\nhi" }, build({ { kind = "prompt" } }, "hi", opts))
      assert.same({ "/bin/fake-cli", "hi" }, build({ { kind = "prompt" } }, "hi", opts, "s1"))
    end)

    it("prepends the language sentence only where asked, and spells the flag three ways", function()
      local config = { language = "ja" }
      assert.same({ "/bin/fake-cli", "--", "hi" }, build({ { kind = "prompt", terminator = "--" } }, "hi", {}, nil, config))
      assert.same(
        { "/bin/fake-cli", "-p", "Always respond in Japanese (ja).\n\nhi" },
        build({ { kind = "prompt", flag = "-p", language_prefix = true } }, "hi", {}, nil, config)
      )
      assert.same({ "/bin/fake-cli", "--single=hi" }, build({ { kind = "prompt", flag_eq = "--single=" } }, "hi", {}, nil, config))
    end)
  end)

  describe("extra", function()
    it("appends whatever the function returns, and tolerates nil", function()
      local seen = nil
      local parts = {
        { kind = "extra", fn = function(ctx)
          seen = ctx
          return { "--x", ctx.prompt }
        end },
        { kind = "extra", fn = function()
          return nil
        end },
      }
      assert.same({ "/bin/fake-cli", "--x", "hi" }, build(parts, "hi", {}, "s1", {}, "h"))
      assert.equals("s1", seen.session_id)
      assert.equals("h", seen.hook_arg)
    end)
  end)

  it("refuses a part kind it does not know", function()
    assert.has_error(function()
      build({ { kind = "teleport" } })
    end)
  end)

  it("resolves a named binary once and confirms it is still there", function()
    local installed = helper.fake_binary("rb")
    local lookups = 0
    local original = vim.fn.exepath
    vim.fn.exepath = function()
      lookups = lookups + 1
      return installed
    end
    local spec = { binary = { name = "request-builder-spec-cli", missing = "nope" }, parts = {} }
    RequestBuilder.reset_binary(spec)
    RequestBuilder.build(spec, "hi", {}, nil, {})
    RequestBuilder.build(spec, "hi", {}, nil, {})
    vim.fn.exepath = original
    assert.equals(1, lookups)
  end)
end)
