-- セッション検索のエージェントが触れてよいのは、ログを読む2つの MCP ツールとそれを引く
-- ToolSearch だけ。vibing-nvim の MCP ツールは既定で許可されるので、`nvim_execute` まで
-- 通ってしまわないことがこの依頼の前提になる。
local SessionPrompt = require("vibing.application.chat.search.session_prompt")
local BackgroundAgent = require("vibing.application.chat.search.background_agent")
local helper = require("tests.helpers.background_agent_permissions")

describe("session search prompt", function()
  local opts = BackgroundAgent.opts({}, "/repo", SessionPrompt.TOOLS, function() end)

  it("lets the session tools through under both registration styles", function()
    for _, prefix in ipairs({ "mcp__vibing-nvim__", "mcp__plugin_vibing-nvim_vibing-nvim__" }) do
      assert.are.equal("allow", helper.decide(opts, prefix .. "nvim_session_search", { query = "x" }), prefix)
      assert.are.equal("allow", helper.decide(opts, prefix .. "nvim_session_read", {}), prefix)
    end
    assert.are.equal("allow", helper.decide(opts, "ToolSearch", { query = "select:x" }))
  end)

  it("refuses every other tool, the other vibing-nvim MCP tools included", function()
    assert.are.equal("deny", helper.decide(opts, "mcp__plugin_vibing-nvim_vibing-nvim__nvim_execute", {}))
    assert.are.equal("deny", helper.decide(opts, "mcp__vibing-nvim__nvim_chat_send_message", {}))
    assert.are.equal("deny", helper.decide(opts, "Read", { file_path = "/etc/hosts" }))
    assert.are.equal("deny", helper.decide(opts, "Bash", { command = "ls" }))
  end)

  it("tells the agent to skip earlier searches by how they open", function()
    local prompt = SessionPrompt.build("oauth", "/repo", nil)

    assert.is_true(vim.startswith(prompt, SessionPrompt.OPENING))
    assert.is_truthy(prompt:find('starts with "Find the past"', 1, true))
    assert.is_true(vim.startswith(require("vibing.application.chat.search.chat_prompt").build("x", "/d"), "Find the past"))
    assert.is_truthy(prompt:find("oauth", 1, true))
  end)
end)
