-- Tests for vibing.presentation.chat.modules.frontmatter_handler

local handler = require("vibing.presentation.chat.modules.frontmatter_handler")

describe("frontmatter_handler.update_field", function()
  local buf

  ---@param lines string[]
  local function open(lines)
    buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    return buf
  end

  ---@return string[]
  local function frontmatter_lines()
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local out = {}
    for i = 2, #lines do
      if lines[i] == "---" then
        break
      end
      table.insert(out, lines[i])
    end
    return out
  end

  after_each(function()
    if buf and vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_delete(buf, { force = true })
    end
  end)

  it("replaces an existing line for the same key", function()
    open({ "---", "permission_mode: default", "---", "" })

    assert.is_true(handler.update_field(buf, "permission_mode", "plan", false))
    assert.same({ "permission_mode: plan" }, frontmatter_lines())
  end)

  it("appends the key when the frontmatter does not have it yet", function()
    open({ "---", "session_id: abc", "---", "" })

    assert.is_true(handler.update_field(buf, "permission_mode", "plan", false))
    assert.same({ "session_id: abc", "permission_mode: plan" }, frontmatter_lines())
  end)

  it("rewrites a legacy plural line in place instead of adding a duplicate", function()
    -- A chat written against the old README. Writing the canonical key must not leave the file
    -- carrying the same setting twice under two spellings.
    open({ "---", "permissions_mode: default", "---", "" })

    assert.is_true(handler.update_field(buf, "permission_mode", "plan", false))
    assert.same({ "permission_mode: plan" }, frontmatter_lines())
  end)
end)
