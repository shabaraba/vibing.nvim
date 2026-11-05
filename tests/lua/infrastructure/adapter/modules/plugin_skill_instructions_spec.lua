local PluginSkills = require("vibing.infrastructure.adapter.modules.plugin_skill_instructions")

describe("plugin_skill_instructions", function()
  it("renders the listing and the leading /name fallback", function()
    local lines = PluginSkills.lines({
      { plugin = "vibing-nvim", skill = { name = "vibing-worker", description = "Do the work.", path = "/p/SKILL.md" } },
    })
    local text = table.concat(lines, "\n")

    assert.is_truthy(text:find("- vibing-nvim:vibing-worker: Do the work.", 1, true))
    assert.is_truthy(text:find("  SKILL.md: /p/SKILL.md", 1, true))
    -- Without this sentence a CLI with no native slash skills answers "isn't a command I
    -- recognize"; measured on Command Code 1.88.2 over ACP.
    assert.is_truthy(text:find("When a message begins with /<skill-name>", 1, true))
  end)

  it("is empty when no plugin bundles a skill", function()
    assert.same({}, PluginSkills.lines({}))
  end)
end)
