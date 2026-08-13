local chat_excerpt = require("vibing.core.utils.chat_excerpt")

describe("chat_excerpt.clean", function()
  it("drops tool call headers including multi-line arguments", function()
    local text = table.concat({
      "原因が特定できました。",
      "💻 Bash(cd /repo",
      "git status --short",
      "git log --oneline -5)",
      "修正します。",
    }, "\n")

    local cleaned = chat_excerpt.clean(text)

    assert.equals("原因が特定できました。\n修正します。", cleaned)
  end)

  it("drops tool result blocks and their indented continuation lines", function()
    local text = table.concat({
      "⏺ Read(/repo/init.lua)",
      "  ⎿  local M = {}",
      "     return M",
      "読みました。",
    }, "\n")

    assert.equals("読みました。", chat_excerpt.clean(text))
  end)

  it("drops tool headers whose marker was customised in config", function()
    -- config.ui.tool_markers is user-configurable, so glyph matching alone is not enough:
    -- the "<symbol> Name(" shape has to be recognised structurally.
    assert.equals("done", chat_excerpt.clean("✿ SomeTool(arg)\ndone"))
  end)

  it("keeps markdown bullets that mention a function call", function()
    -- "- fix parse(input)" has the same "<symbol> name(" shape as a tool header. Dropping it
    -- would delete the user's actual request, so the structural match requires a non-ASCII
    -- marker; ASCII bullets are not tool markers.
    local text = "- fix parse(input)\n* rename build(x)\n> check run(y)"

    assert.equals(text, chat_excerpt.clean(text))
  end)

  it("stops swallowing a tool header's arguments at a blank line", function()
    -- A shell command can contain unbalanced parens (`case x)`), so paren counting alone
    -- would eat every following line. A blank line ends the header instead.
    local text = table.concat({
      "💻 Bash(case $x in",
      "  a) echo a;;",
      "",
      "この後の説明は残す",
    }, "\n")

    assert.equals("この後の説明は残す", chat_excerpt.clean(text))
  end)

  it("drops tool result continuation lines indented deeper than five spaces", function()
    local text = table.concat({
      "  ⎿  {",
      '       "key": "value"',
      "     }",
      "結果を読みました。",
    }, "\n")

    assert.equals("結果を読みました。", chat_excerpt.clean(text))
  end)

  it("drops fenced code blocks, @file: context and HTML comments", function()
    local text = table.concat({
      "@file:lua/vibing/init.lua:L10-L20",
      "```lua",
      "local x = 1",
      "```",
      "<!-- patch: .vibing/patches/abc.patch -->",
      "この関数を直して",
    }, "\n")

    assert.equals("この関数を直して", chat_excerpt.clean(text))
  end)

  it("drops rate-limit notices so they cannot become the topic", function()
    local text = "**Error:** You've hit your session limit · resets 3:40am\n\n*Session has been reset. Your next message will start a new session.*"

    assert.equals("", chat_excerpt.clean(text))
  end)
end)

describe("chat_excerpt.is_tool_line", function()
  it("recognises rendered tool lines and leaves prose alone", function()
    assert.is_true(chat_excerpt.is_tool_line("⏺ ToolSearch(select:TaskList)"))
    assert.is_false(chat_excerpt.is_tool_line("認証まわりのバグ修正"))
    assert.is_false(chat_excerpt.is_tool_line("- fix parse(input)"))
  end)
end)

describe("chat_excerpt.build", function()
  it("keeps every user request, not just the tail", function()
    local conversation = {
      { role = "user", content = "認証まわりのバグを直したい" },
      { role = "assistant", content = "調べます。" },
      { role = "user", content = "つづけて" },
      { role = "assistant", content = "直しました。" },
      { role = "user", content = "ではマージしてcleanup" },
      { role = "assistant", content = "マージと後片付けが完了しました。" },
    }

    local excerpt = chat_excerpt.build(conversation)

    assert.is_not_nil(excerpt:find("認証まわりのバグを直したい", 1, true))
    assert.is_not_nil(excerpt:find("ではマージしてcleanup", 1, true))
  end)

  it("excludes the closing assistant report, which describes the wrap-up not the topic", function()
    local conversation = {
      { role = "user", content = "認証まわりのバグを直したい" },
      { role = "assistant", content = "調べます。" },
      { role = "assistant", content = "直しました。" },
      { role = "assistant", content = "マージと後片付けが完了しました。" },
    }

    local excerpt = chat_excerpt.build(conversation)

    assert.is_not_nil(excerpt:find("調べます。", 1, true))
    assert.is_nil(excerpt:find("マージと後片付けが完了しました。", 1, true))
  end)

  it("drops auto-resume boilerplate user messages", function()
    local conversation = {
      { role = "user", content = "認証まわりのバグを直したい" },
      { role = "user", content = "Continue from where you left off." },
    }

    local excerpt = chat_excerpt.build(conversation)

    assert.is_nil(excerpt:find("Continue from where", 1, true))
  end)

  it("labels user requests as the subject and assistant replies as background", function()
    local excerpt = chat_excerpt.build({
      { role = "user", content = "topic" },
      { role = "assistant", content = "reply" },
    })

    assert.is_not_nil(excerpt:find("USER REQUESTS", 1, true))
    assert.is_not_nil(excerpt:find("background only", 1, true))
  end)

  it("bounds a long conversation", function()
    local conversation = {}
    for i = 1, 40 do
      conversation[#conversation + 1] = { role = "user", content = "request " .. i .. " " .. string.rep("あ", 2000) }
      conversation[#conversation + 1] = { role = "assistant", content = "reply " .. i .. " " .. string.rep("い", 2000) }
    end

    local excerpt = chat_excerpt.build(conversation)

    assert.is_not_nil(excerpt:find("request 1 ", 1, true))
    assert.is_not_nil(excerpt:find("request 40 ", 1, true))
    assert.is_nil(excerpt:find("request 20 ", 1, true))
    assert.is_true(vim.fn.strchars(excerpt) <= 6001)
  end)
end)
