local Agents = require("vibing.core.constants.agents")

describe("agent executable paths", function()
  for _, id in ipairs({ "claude", "codex", "copilot" }) do
    it("uses the explicit path for " .. id, function()
      local descriptor = require(Agents.get(id).descriptor_module)
      local cmd = descriptor.build(
        "hi",
        { lightweight = true },
        nil,
        { ai = { agents = { [id] = { path = "/bin/sh" } } } },
        nil
      )
      assert.equals("/bin/sh", cmd[1])
    end)
    it("refuses a missing explicit " .. id .. " path instead of searching PATH", function()
      local descriptor = require(Agents.get(id).descriptor_module)
      local ok, err = pcall(
        descriptor.build,
        "hi",
        { lightweight = true },
        nil,
        { ai = { agents = { [id] = { path = "/missing/vibing-config-agent" } } } },
        nil
      )
      assert.is_false(ok)
      assert.truthy(err:find("ai.agents." .. id .. ".path", 1, true))
    end)
  end
end)
