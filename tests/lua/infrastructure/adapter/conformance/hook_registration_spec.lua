---@diagnostic disable: undefined-field
--- Contract C5 of ADR 009: every backend's PreToolUse hook is registered through a transport the
--- shared script can actually serve, and skipped exactly where the contract says.
local Agents = require("vibing.core.constants.agents")
local Transports = require("vibing.infrastructure.hooks.transports")

describe("conformance: hook registration", function()
  local script = table.concat(vim.fn.readfile(vim.fn.getcwd() .. "/bin/hooks/pre-tool-use.sh"), "\n")

  for _, def in ipairs(Agents.list()) do
    local descriptor = require(def.descriptor_module)

    describe(def.id, function()
      it("declares a hook", function()
        -- A backend with no hook has no permission gate, no approval UI and no diff baseline.
        -- One that genuinely cannot register one has to say so here, deliberately.
        assert.is_table(descriptor.hook, def.id .. " registers no PreToolUse hook")
      end)

      it("names a transport the registry knows", function()
        assert.is_true(vim.tbl_contains(Transports.NAMES, descriptor.hook.transport))
      end)

      it("speaks a dialect pre-tool-use.sh implements", function()
        local dialect = descriptor.hook.dialect or "claude"
        assert.is_true(Transports.DIALECTS[dialect] == true, dialect .. " is not a known dialect")
        -- The script's default is claude; any other dialect must have its own branch, or the
        -- decision is emitted in a shape the CLI ignores -- which fails open.
        if dialect ~= "claude" then
          assert.is_truthy(
            script:find('"$FORMAT" = "' .. dialect .. '"', 1, true),
            "pre-tool-use.sh has no branch for dialect " .. dialect
          )
        end
      end)

      it("never registers the hook on a lightweight call", function()
        assert.is_false(Transports.wanted(descriptor.hook, { lightweight = true }))
        assert.is_false(Transports.wanted(descriptor.hook, { lightweight = true, permission_mode = "bypassPermissions" }))
      end)

      it("registers it for an ordinary call in every non-bypass mode", function()
        for _, mode in ipairs({ "default", "acceptEdits", "plan", "auto", "dontAsk" }) do
          assert.is_true(Transports.wanted(descriptor.hook, { permission_mode = mode }), mode)
        end
        assert.is_true(Transports.wanted(descriptor.hook, {}))
      end)

      it("follows keep_in_bypass in bypassPermissions", function()
        assert.equals(
          descriptor.hook.keep_in_bypass == true,
          Transports.wanted(descriptor.hook, { permission_mode = "bypassPermissions" })
        )
      end)
    end)
  end

  it("refuses a transport or dialect it does not know", function()
    assert.has_error(function()
      Transports.install({ transport = "carrier_pigeon" }, vim.fn.tempname())
    end)
    assert.has_error(function()
      Transports.install({ transport = "settings_file", dialect = "morse" }, vim.fn.tempname())
    end)
  end)
end)
