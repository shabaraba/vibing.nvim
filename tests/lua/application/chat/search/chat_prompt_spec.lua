-- チャットバッファの無いターンなので、承認を尋ねる先が無い。渡したツールの外は尋ねずに拒否
-- させる、というのがこの依頼の前提で、崩れると検索のたびにターンが止まる。
local ChatPrompt = require("vibing.application.chat.search.chat_prompt")
local BackgroundAgent = require("vibing.application.chat.search.background_agent")
local helper = require("tests.helpers.background_agent_permissions")

describe("chat search prompt", function()
  local opts = BackgroundAgent.opts({}, "/repo", ChatPrompt.TOOLS, function() end)

  it("lets the read-only tools and the gh lookups through", function()
    assert.are.equal("allow", helper.decide(opts, "Grep", { pattern = "x" }))
    assert.are.equal("allow", helper.decide(opts, "Read", { file_path = "/repo/a.md" }))
    assert.are.equal("allow", helper.decide(opts, "Bash", { command = "gh pr view 876 --json title" }))
    assert.are.equal("allow", helper.decide(opts, "Bash", { command = "rg -c foo .vibing/chat" }))
  end)

  it("refuses anything else without asking, the vibing-nvim MCP tools included", function()
    assert.are.equal("deny", helper.decide(opts, "Write", { file_path = "/repo/a.md" }))
    assert.are.equal("deny", helper.decide(opts, "Bash", { command = "gh pr merge 876" }))
    assert.are.equal("deny", helper.decide(opts, "Bash", { command = "touch x" }))
    assert.are.equal("deny", helper.decide(opts, "Agent", { prompt = "x" }))
    assert.are.equal("deny", helper.decide(opts, "mcp__plugin_vibing-nvim_vibing-nvim__nvim_execute", {}))
  end)

  it("names the query and the directory", function()
    local prompt = ChatPrompt.build("pull/70332", "/repo/.vibing/chat", "Japanese")

    assert.is_truthy(prompt:find("pull/70332", 1, true))
    assert.is_truthy(prompt:find("/repo/.vibing/chat", 1, true))
    assert.is_truthy(prompt:find("Japanese", 1, true))
  end)
end)
