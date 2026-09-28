---@diagnostic disable: undefined-field
--- Where a rendered tool call ends, asked of the two things that answer it.
---
--- `tool_input.command` is put into the header verbatim, so a `Bash` call can be a whole script.
--- Two places have to know where that script stops: the grammar, which decides what highlights as
--- a tool call and what folds, and `chat_excerpt`, which drops tool output before a chat is handed
--- to title generation or `/summarize`. They are separate implementations -- the grammar's is in C
--- inside the external scanner and cannot call Lua -- so this holds them to the same answers.
---
--- `chat_excerpt`'s is the older one and was arrived at by measurement: parentheses decide, quoted
--- spans and escapes do not count, a heredoc body is data. The scanner is a port of that rule, and
--- the fixtures below are the cases that shaped it.

local ChatExcerpt = require("vibing.core.utils.chat_excerpt")
local VibingLanguage = require("tests.helpers.vibing_language")

describe("where a rendered tool call ends", function()
  before_each(function()
    VibingLanguage.ensure()
  end)

  --- Each fixture is the call's own lines. `after` is the prose that must survive it.
  local CALLS = {
    {
      what = "a script whose own lines close parentheses",
      lines = {
        '💻 Bash(cd /tmp && nvim --headless -u NONE -c "',
        "call setline(1, ['a'])",
        "echo foldclosedend(1)",
        "qa!",
        '" 2>&1)',
      },
    },
    -- The body is data, so its parentheses are not the command's. This one is unbalanced on
    -- purpose: a Python triple-quoted string spanning lines is what first exposed this.
    {
      what = "a heredoc body that is not shell code",
      lines = {
        "💻 Bash(python3 - <<'PY'",
        'text = """',
        "close ) paren",
        '"""',
        "print(text)",
        "PY",
        "echo done)",
      },
    },
    -- Reported from a call that posted Markdown to an API. Its argument is full of `##` headings,
    -- and a chat boundary is what stops the search for a closing parenthesis -- so a heading that
    -- is not one must not be mistaken for one, or the call never ends and nothing folds.
    {
      what = "Markdown headings inside the argument",
      lines = {
        "💻 Bash(gh api -X POST /markdown -f mode=gfm -f text='## ✳ Configuration",
        "",
        "## 📋 Requirements",
        "",
        "- Neovim 0.10",
        "')",
      },
    },
    {
      what = "a heredoc the command ends on",
      lines = {
        "💻 Bash(python3 - <<'PY'",
        's = "(".join(parts)',
        "PY)",
      },
    },
    -- The second line of each of these ends in `)`, so the call ending where its parentheses
    -- close and the call ending at the first line that looks closed are different answers.
    {
      what = "a quoted parenthesis that closes nothing",
      lines = {
        "💻 Bash(echo ')' && nvim --headless -c \"",
        "call setline(1)",
        "quit",
        '" && true)',
      },
    },
    {
      what = "an escaped quote, which does not open a quoted span",
      lines = {
        "💻 Bash(echo 'it\\'s (' && nvim --headless -c \"",
        "call setline(1)",
        "quit",
        '" && true)',
      },
    },
    {
      what = "a call that fits on one line",
      lines = {
        "💻 Bash(ls)",
      },
    },
  }

  --- @param lines string[]
  --- @return integer last 1-indexed last line the grammar puts inside the tool block
  local function grammar_end(lines)
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)

    local parser = vim.treesitter.get_parser(bufnr, "vibing")
    local root = parser:parse(false)[1]:root()

    local last
    for node in root:iter_children() do
      if node:type() == "tool_block" then
        local _, _, end_row, end_col = node:range()
        last = end_col == 0 and end_row or end_row + 1
      end
    end

    vim.api.nvim_buf_delete(bufnr, { force = true })
    return last
  end

  for _, call in ipairs(CALLS) do
    it("agrees on " .. call.what, function()
      local after = "この文は残らなければならない。"
      local lines = vim.list_extend(vim.deepcopy(call.lines), { after })

      assert.equals(#call.lines, grammar_end(lines), "the grammar disagrees")

      -- `clean` drops every line of the call and keeps the prose. A block that ended early leaves
      -- the rest of the script behind as the user's own words.
      local cleaned = ChatExcerpt.clean(table.concat(lines, "\n"))
      assert.equals(after, vim.trim(cleaned), "chat_excerpt disagrees")
    end)
  end

  -- Both give up rather than reading on forever, and both give up in the same direction: the
  -- prose below an argument that never closes is prose, not part of the call.
  it("agrees that an argument which never closes does not eat the chat", function()
    local lines = {
      '💻 Bash(echo "(((',
      "",
      "## Assistant",
      "",
      "答え。",
    }

    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    local root = vim.treesitter.get_parser(bufnr, "vibing"):parse(false)[1]:root()

    local kinds = {}
    for node in root:iter_children() do
      kinds[node:type()] = true
    end
    assert.is_nil(kinds.tool_block, "the call swallowed the chat boundary")
    assert.is_true(kinds.message_header, "the chat boundary was lost")
    vim.api.nvim_buf_delete(bufnr, { force = true })

    -- `clean` keeps the chat's own headers; what matters is that it stopped at the call rather
    -- than reading the rest of the conversation as its argument.
    local cleaned = ChatExcerpt.clean(table.concat(lines, "\n"))
    assert.is_nil(cleaned:find('echo "(((', 1, true), "the unclosed call was left in")
    assert.is_truthy(cleaned:find("答え。", 1, true), "the prose below it was eaten")
  end)
end)
