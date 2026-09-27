local VibingLanguage = require("tests.helpers.vibing_language")

describe("vibing Tree-sitter parser", function()
  local ensure_language = VibingLanguage.ensure

  it("isolates chat sections and rendered tool blocks from Markdown injections", function()
    ensure_language()
    local outer_highlights = vim.treesitter.query.get("vibing", "highlights")
    assert.is_not_nil(
      outer_highlights,
      "the outer query is required to activate injected highlighting"
    )
    assert.same({ "comment" }, outer_highlights.captures)

    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "## User",
      "",
      "```markdown",
      "unclosed fence",
      "",
      "## Assistant",
      "",
      "normal `code`",
      "💻 Bash(for value in $(list); do",
      'echo "$value"',
      "done)",
      "  ⎿  result $5",
      "     more",
      "after **strong**",
      "",
      "## User",
      "",
      "next",
      "````markdown",
      "```lua",
      '💻 Bash(echo "$inside")',
      "print('nested')",
      "```",
      "````",
      "`across",
      "line`",
    })

    local parser = vim.treesitter.get_parser(buf, "vibing")
    local root = parser:parse(true)[1]:root()
    assert.is_false(root:has_error())
    assert.is_truthy(root:sexpr():find("tool_header_open", 1, true))
    assert.is_truthy(root:sexpr():find("tool_result_continuation", 1, true))

    local found_nested_fence = false
    local found_multiline_code_span = false
    local found_lua_injection = false
    local function inspect_node(node)
      local start_row, _, end_row, _ = node:range()
      if node:type() == "fenced_code_block" and start_row == 18 and end_row == 24 then
        found_nested_fence = true
      elseif node:type() == "code_span" and start_row == 24 and end_row == 25 then
        found_multiline_code_span = true
      end
      for child in node:iter_children() do
        inspect_node(child)
      end
    end
    parser:for_each_tree(function(tree, language_tree)
      if language_tree:lang() == "lua" then
        found_lua_injection = true
      end
      inspect_node(tree:root())
    end)

    -- Markdown remains the real Markdown parser: a four-backtick fence can contain a
    -- three-backtick Lua fence, and CommonMark's multiline single-backtick span still parses.
    assert.is_true(found_nested_fence)
    assert.is_true(found_lua_injection)
    assert.is_true(found_multiline_code_span)
    assert.is_truthy(root:sexpr():find("fenced_markdown_block", 1, true))

    vim.treesitter.start(buf, "vibing")
    local has_markdown_highlight = false
    for _, capture in ipairs(vim.treesitter.get_captures_at_pos(buf, 13, 8)) do
      if capture.lang == "markdown" or capture.lang == "markdown_inline" then
        has_markdown_highlight = true
        break
      end
    end
    assert.is_true(
      has_markdown_highlight,
      "the outer query must preserve injected Markdown highlighting"
    )

    local has_tool_highlight = false
    for _, capture in ipairs(vim.treesitter.get_captures_at_pos(buf, 8, 0)) do
      if capture.lang == "vibing" and capture.capture == "comment" then
        has_tool_highlight = true
        break
      end
    end
    assert.is_true(has_tool_highlight, "rendered tool blocks should remain visibly distinct")

    for _, capture in ipairs(vim.treesitter.get_captures_at_pos(buf, 20, 0)) do
      assert.is_false(
        capture.lang == "vibing" and capture.capture == "comment",
        "tool-shaped code must stay inside the fenced Markdown injection"
      )
    end

    for _, capture in ipairs(vim.treesitter.get_captures_at_pos(buf, 0, 3)) do
      assert.is_false(
        capture.lang == "vibing",
        "message headers should only be highlighted by injected Markdown"
      )
    end

    local injection_query = assert(vim.treesitter.query.get("vibing", "injections"))
    local ranges = {}
    for _, match, metadata in injection_query:iter_matches(root, buf, 0, -1) do
      assert.equals("markdown", metadata["injection.language"])
      for capture_id, nodes in pairs(match) do
        if injection_query.captures[capture_id] == "injection.content" then
          for _, node in ipairs(nodes) do
            local start_row, _, end_row, _ = node:range()
            ranges[#ranges + 1] = { start_row, end_row }
          end
        end
      end
    end

    -- User's unfinished fence ends at the next reserved chat header rather than swallowing it.
    assert.same({ 1, 5 }, ranges[2])
    assert.same({ 5, 6 }, ranges[3])

    -- Rows 8..12 are the rendered tool block, including multiline shell and result text. None of
    -- them are offered to the Markdown parser, so `$` cannot become a cross-line LaTeX span.
    for _, range in ipairs(ranges) do
      assert.is_false(range[1] < 13 and range[2] > 8)
    end

    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  -- A node name this query gets wrong does not degrade quietly: `query.get` raises, and the chat
  -- window is left on a `foldmethod=expr` that errors once per line.
  it("folds rendered tool blocks and reasoning, and leaves the answer alone", function()
    ensure_language()
    local folds = vim.treesitter.query.get("vibing", "folds")
    assert.is_not_nil(folds, "queries/vibing/folds.scm must load against the grammar")
    assert.same({ "fold" }, folds.captures)

    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "## Assistant", -- 0
      "💭 first thought", -- 1
      "💭", -- 2
      "💭 second thought", -- 3
      "Here is the answer.", -- 4
      "", -- 5
      "⏺ Bash(ls)", -- 6
      "  ⎿  a.txt", -- 7
      "     b.txt", -- 8
      "", -- 9
      "Done.", -- 10
    })
    local root = vim.treesitter.get_parser(buf, "vibing"):parse(true)[1]:root()
    assert.is_false(root:has_error())

    local folded = {}
    for _, node in folds:iter_captures(root, buf) do
      local start_row, _, end_row, end_col = node:range()
      folded[#folded + 1] = { start_row, end_col == 0 and end_row - 1 or end_row }
    end

    -- Reasoning is rows 1..3 and the tool block rows 6..8. Row 4 is the answer and row 10 the
    -- prose after the tool, and neither may be inside a fold.
    assert.same({ { 1, 3 }, { 6, 8 } }, folded)

    vim.api.nvim_buf_delete(buf, { force = true })
  end)
end)
