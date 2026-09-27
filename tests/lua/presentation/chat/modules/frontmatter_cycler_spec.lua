-- Tests for vibing.presentation.chat.modules.frontmatter_cycler
--
-- The candidate lists are not restated here: they are read back out of the completion provider,
-- which is the point of the module. A test that hardcoded "low comes after default" would pass
-- while the two sources of truth drifted apart, which is the failure the design rules out.

local cycler = require("vibing.presentation.chat.modules.frontmatter_cycler")
local provider = require("vibing.infrastructure.completion.providers.frontmatter")
local Agents = require("vibing.core.constants.agents")

---@param field string
---@return string[]
local function candidates(field)
  local out = {}
  for _, item in ipairs(provider.get_enum_values(field)) do
    table.insert(out, item.word)
  end
  return out
end

---@param agent string
---@return string[]
local function model_candidates(agent)
  local out = {}
  for _, m in ipairs(Agents.models_for(agent)) do
    table.insert(out, m.value)
  end
  return out
end

describe("frontmatter_cycler", function()
  local buf

  ---バッファは作るだけで、ウィンドウには出さない。`enum_at` は問い合わせるバッファを
  ---引数で受け取るので、それがカレントバッファに化けていると引数が効いているか分からない
  ---@param lines string[]
  local function open(lines)
    buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    return buf
  end

  ---バッファをウィンドウに出し、カーソルを `<field>:` の行に置く（`cycle` はカーソルを読む）
  ---@param field string
  local function cursor_on(field)
    vim.api.nvim_win_set_buf(0, buf)
    for i, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
      if line:match("^" .. field .. ":") then
        vim.api.nvim_win_set_cursor(0, { i, 0 })
        return i
      end
    end
    error("no line for field: " .. field)
  end

  ---@param field string
  ---@return string?
  local function value_of(field)
    for _, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
      local v = line:match("^" .. field .. ":%s*(.*)$")
      if v then
        return vim.trim(v)
      end
    end
    return nil
  end

  after_each(function()
    if buf and vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_delete(buf, { force = true })
    end
  end)

  describe("enum_at", function()
    it("reports the field, its current value and the completion candidates", function()
      open({ "---", "effort: low", "---", "" })

      local found = cycler.enum_at(buf, 2)

      assert.equals("effort", found.field)
      assert.equals("low", found.value)
      assert.same(candidates("effort"), found.values)
    end)

    it("ignores a line outside the frontmatter that looks like a field", function()
      -- The completion source only ever sees the line the cursor is on, so it has no region
      -- check. The cycler writes to the buffer, so prose that happens to read `effort: low`
      -- must not be a target.
      open({ "---", "session_id: abc", "---", "", "## User", "", "effort: low", "" })

      assert.is_nil(cycler.enum_at(buf, 7))
    end)

    it("ignores the line immediately after the closing delimiter", function()
      -- The boundary case for the region check: one line further and the field would be
      -- inside. `---` itself never matches an enum pattern, so the delimiters are not what
      -- the check is for — this is.
      open({ "---", "session_id: abc", "---", "effort: low" })

      assert.is_nil(cycler.enum_at(buf, 4))
    end)

    it("ignores a field the provider defines no values for", function()
      -- `mode` is in the completion source's enum-field list but has no entry in ENUMS, so
      -- there is nothing to cycle through.
      open({ "---", "mode: code", "---", "" })

      assert.is_nil(cycler.enum_at(buf, 2))
    end)

    it("offers the models of the agent this chat is using", function()
      open({ "---", "agent: codex", "model: gpt-5", "---", "" })

      assert.same(model_candidates("codex"), cycler.enum_at(buf, 3).values)
    end)
  end)

  describe("cycle", function()
    it("moves to the next candidate", function()
      local values = candidates("effort")
      open({ "---", "effort: " .. values[1], "---", "" })
      cursor_on("effort")

      assert.is_true(cycler.cycle(buf, 1))
      assert.equals(values[2], value_of("effort"))
    end)

    it("moves to the previous candidate", function()
      local values = candidates("effort")
      open({ "---", "effort: " .. values[2], "---", "" })
      cursor_on("effort")

      assert.is_true(cycler.cycle(buf, -1))
      assert.equals(values[1], value_of("effort"))
    end)

    it("wraps at the end of the list", function()
      local values = candidates("permission_mode")
      open({ "---", "permission_mode: " .. values[#values], "---", "" })
      cursor_on("permission_mode")

      assert.is_true(cycler.cycle(buf, 1))
      assert.equals(values[1], value_of("permission_mode"))
    end)

    it("wraps at the start of the list", function()
      local values = candidates("permission_mode")
      open({ "---", "permission_mode: " .. values[1], "---", "" })
      cursor_on("permission_mode")

      assert.is_true(cycler.cycle(buf, -1))
      assert.equals(values[#values], value_of("permission_mode"))
    end)

    it("goes to the first candidate from a value that is not in the list", function()
      open({ "---", "effort: nonsense", "---", "" })
      cursor_on("effort")

      assert.is_true(cycler.cycle(buf, 1))
      assert.equals(candidates("effort")[1], value_of("effort"))
    end)

    it("goes to the last candidate backwards from a value that is not in the list", function()
      local values = candidates("effort")
      open({ "---", "effort: nonsense", "---", "" })
      cursor_on("effort")

      assert.is_true(cycler.cycle(buf, -1))
      assert.equals(values[#values], value_of("effort"))
    end)

    it("treats a field with no value as not being in the list", function()
      open({ "---", "effort:", "---", "" })
      cursor_on("effort")

      assert.is_true(cycler.cycle(buf, 1))
      assert.equals(candidates("effort")[1], value_of("effort"))
    end)

    it("keeps the cursor on the field so the next press continues from there", function()
      -- The write goes through parse -> serialize, which re-orders the region into KEY_ORDER,
      -- so the line the user was on can move out from under the cursor. Two presses landing two
      -- candidates along is what says it did not.
      local values = candidates("effort")
      open({ "---", "effort: " .. values[1], "session_id: abc", "---", "" })
      cursor_on("effort")

      assert.is_true(cycler.cycle(buf, 1))
      assert.is_true(cycler.cycle(buf, 1))
      assert.equals(values[3], value_of("effort"))
    end)

    it("does not touch updated_at", function()
      -- Cycling is the user editing the value by hand, and typing over it writes no timestamp.
      open({ "---", "effort: " .. candidates("effort")[1], "updated_at: 2020-01-01T00:00:00", "---", "" })
      cursor_on("effort")

      assert.is_true(cycler.cycle(buf, 1))
      assert.equals("2020-01-01T00:00:00", value_of("updated_at"))
    end)

    it("refuses and leaves the buffer alone when the cursor is not on an enum field", function()
      open({ "---", "session_id: abc", "---", "", "## User", "", "hello", "" })
      local before = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      vim.api.nvim_win_set_buf(0, buf)
      vim.api.nvim_win_set_cursor(0, { 7, 0 })

      assert.is_false(cycler.cycle(buf, 1))
      assert.same(before, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
    end)
  end)
end)
