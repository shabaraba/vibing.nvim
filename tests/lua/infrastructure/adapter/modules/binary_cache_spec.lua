local helper = require("tests.helpers.adapter_stream")
local Agents = require("vibing.core.constants.agents")

--- grok is deliberately absent from the cached set: it resolves a configurable executable name and
--- sniffs it for executability, which is a different operation from "look this name up on PATH
--- once". Listing the exceptions here rather than deriving them keeps that a stated decision.
local UNCACHED = { grok = true }

describe("command builder binary caching", function()
  local original_exepath

  before_each(function()
    original_exepath = vim.fn.exepath
    helper.reset_path_caches()
  end)

  after_each(function()
    vim.fn.exepath = original_exepath
    helper.reset_path_caches()
  end)

  for _, def in ipairs(Agents.list()) do
    if not UNCACHED[def.id] then
      local builder = require(def.command_builder_module)

      it(def.id .. " resolves its binary once, not once per request", function()
        local lookups = 0
        vim.fn.exepath = function(name)
          lookups = lookups + 1
          return "/usr/local/bin/" .. name
        end

        builder.build("hi", {}, nil, {}, nil)
        builder.build("hi", {}, nil, {}, nil)
        builder.build("hi", {}, nil, {}, nil)

        assert.equals(1, lookups, def.id .. " called exepath " .. lookups .. " times")
      end)

      it(def.id .. " exposes the reset seam every cached builder needs", function()
        -- Without it, one spec's resolved path outlives the spec and the next one's "CLI missing"
        -- case never reaches the missing-CLI branch. helper.reset_path_caches walks the registry.
        assert.is_function(builder._reset_path_cache)
      end)

      it(def.id .. " reports a missing binary rather than caching the absence", function()
        vim.fn.exepath = function()
          return ""
        end

        local ok, err = pcall(builder.build, "hi", {}, nil, {}, nil)
        assert.is_false(ok)
        assert.is_truthy(tostring(err):lower():find("not found", 1, true))

        vim.fn.exepath = function(name)
          return "/usr/local/bin/" .. name
        end
        assert.is_true(pcall(builder.build, "hi", {}, nil, {}, nil), "a later lookup should succeed")
      end)
    end
  end
end)
