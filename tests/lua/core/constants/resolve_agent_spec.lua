-- Modes.resolve_agent: which backend a chat actually talks to.
--
-- Anything scoped per backend (the usage-limit record, for one) has to agree with what
-- send_message._resolve_adapter picks, or it scopes itself to a backend the chat never uses.

describe("Modes.resolve_agent", function()
  local Modes = require("vibing.core.constants.modes")

  it("prefers the chat's own frontmatter", function()
    assert.equals("codex", Modes.resolve_agent({ agent = "codex" }, { adapter = "claude" }))
  end)

  it("falls back to the configured adapter", function()
    assert.equals("grok", Modes.resolve_agent({}, { adapter = "grok" }))
  end)

  it("falls back to claude with neither", function()
    assert.equals("claude", Modes.resolve_agent(nil, nil))
  end)

  it("ignores an unknown frontmatter agent, matching _resolve_adapter's own fallback", function()
    assert.equals("codex", Modes.resolve_agent({ agent = "gpt9" }, { adapter = "codex" }))
  end)

  it("ignores an unknown configured adapter", function()
    assert.equals("claude", Modes.resolve_agent({}, { adapter = "nonsense" }))
  end)

  it("ignores a non-string frontmatter agent", function()
    assert.equals("claude", Modes.resolve_agent({ agent = true }, {}))
  end)
end)
