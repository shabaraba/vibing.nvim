describe("subagent_finder", function()
  local finder = require("vibing.presentation.chat.modules.subagent_finder")

  local function buffer_with(lines)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    return buf
  end

  it("finds the markers the event processor left behind", function()
    local refs = finder.find_all(buffer_with({
      "## Assistant",
      "",
      "<!-- subagent: aaa111 type=general-purpose -->",
      "some text",
      "<!-- subagent: bbb222 type=code-reviewer -->",
    }))

    assert.equals(2, #refs)
    assert.equals("aaa111", refs[1].agent_id)
    assert.equals("general-purpose", refs[1].subagent_type)
    assert.equals(3, refs[1].line)
    assert.equals("bbb222", refs[2].agent_id)
  end)

  it("offers one entry per agent even when it was called repeatedly", function()
    local refs = finder.find_all(buffer_with({
      "<!-- subagent: aaa111 type=general-purpose -->",
      "<!-- subagent: aaa111 type=general-purpose -->",
    }))

    assert.equals(1, #refs)
  end)

  it("finds nothing in a chat that never launched one", function()
    assert.same({}, finder.find_all(buffer_with({ "## User", "hello" })))
  end)

  it("ignores prose that merely mentions a subagent", function()
    assert.same({}, finder.find_all(buffer_with({ "I used subagent: aaa111 to check" })))
  end)

  it("returns nothing for an invalid buffer rather than throwing", function()
    local buf = buffer_with({ "<!-- subagent: aaa111 type=x -->" })
    vim.api.nvim_buf_delete(buf, { force = true })
    assert.same({}, finder.find_all(buf))
  end)

  describe("describe", function()
    it("labels a pick by type and a short id", function()
      assert.equals(
        "code-reviewer (bbb222aa)",
        finder.describe({ agent_id = "bbb222aa3333", subagent_type = "code-reviewer" })
      )
    end)

    it("falls back when the type was not recorded", function()
      assert.equals("subagent (aaa111)", finder.describe({ agent_id = "aaa111", subagent_type = "" }))
    end)
  end)
end)
