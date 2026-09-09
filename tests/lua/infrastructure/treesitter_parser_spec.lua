describe("vibing Tree-sitter parser", function()
  it("isolates chat sections and rendered tool blocks from Markdown injections", function()
    local parser_source = assert(
      vim.api.nvim_get_runtime_file("tree-sitter-vibing/src/parser.c", false)[1],
      "generated parser source is missing"
    )
    local include_dir = vim.fn.fnamemodify(parser_source, ":h")
    local parser_library = vim.fn.tempname() .. ".so"
    local compile = vim.system({
      "cc",
      "-O2",
      "-shared",
      "-fPIC",
      "-I" .. include_dir,
      parser_source,
      "-o",
      parser_library,
    }, { text = true }):wait()
    assert.equals(0, compile.code, compile.stderr)
    assert.is_true(vim.treesitter.language.add("vibing", { path = parser_library }))
    assert.is_nil(
      vim.treesitter.query.get("vibing", "highlights"),
      "the outer grammar should not override injected Markdown highlighting"
    )

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
      if node:type() == "fenced_code_block" and start_row == 18 and end_row == 23 then
        found_nested_fence = true
      elseif node:type() == "code_span" and start_row == 23 and end_row == 24 then
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
end)
