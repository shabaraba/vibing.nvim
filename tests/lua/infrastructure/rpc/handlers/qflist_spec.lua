describe("rpc handler set_qflist", function()
  local qflist = require("vibing.infrastructure.rpc.handlers.qflist")

  local existing_file

  before_each(function()
    existing_file = vim.fn.tempname() .. ".lua"
    vim.fn.writefile({ "local M = {}", "return M" }, existing_file)
    -- Start from a known-empty quickfix stack so :colder assertions mean what they say.
    vim.fn.setqflist({}, "f")
  end)

  after_each(function()
    vim.fn.delete(existing_file)
    vim.fn.setqflist({}, "f")
    vim.cmd("cclose")
  end)

  local function stop(overrides)
    return vim.tbl_extend("force", { filename = existing_file, lnum = 2, text = "returns M" }, overrides or {})
  end

  it("pushes the stops as a quickfix list", function()
    local result = qflist.set_qflist({ items = { stop(), stop({ lnum = 1, text = "declares M" }) } })

    assert.is_true(result.success)
    assert.equals(2, result.count)

    local items = vim.fn.getqflist()
    assert.equals(2, #items)
    assert.equals(2, items[1].lnum)
    assert.equals("returns M", items[1].text)
    -- resolve() because the temp dir reaches Neovim through a /var -> /private/var symlink on macOS.
    assert.equals(vim.fn.resolve(existing_file), vim.fn.resolve(vim.api.nvim_buf_get_name(items[1].bufnr)))
  end)

  it("titles the list, defaulting when none is given", function()
    qflist.set_qflist({ items = { stop() }, title = "Code tour: auth" })
    assert.equals("Code tour: auth", vim.fn.getqflist({ title = 0 }).title)

    qflist.set_qflist({ items = { stop() } })
    assert.equals("vibing.nvim", vim.fn.getqflist({ title = 0 }).title)
  end)

  it("keeps whatever list the user already had reachable with :colder", function()
    vim.fn.setqflist({}, " ", { title = "the user's own search", items = { stop({ lnum = 1 }) } })

    qflist.set_qflist({ items = { stop() }, title = "Code tour" })
    assert.equals("Code tour", vim.fn.getqflist({ title = 0 }).title)

    vim.cmd("colder")
    assert.equals("the user's own search", vim.fn.getqflist({ title = 0 }).title)
  end)

  it("passes col through when given", function()
    qflist.set_qflist({ items = { stop({ col = 7 }) } })
    assert.equals(7, vim.fn.getqflist()[1].col)
  end)

  describe("open", function()
    local function quickfix_windows()
      return vim.tbl_filter(function(winnr)
        return vim.bo[vim.api.nvim_win_get_buf(winnr)].buftype == "quickfix"
      end, vim.api.nvim_list_wins())
    end

    it("opens the quickfix window without taking focus", function()
      local before = vim.api.nvim_get_current_win()

      local result = qflist.set_qflist({ items = { stop() }, open = true })

      assert.equals(before, vim.api.nvim_get_current_win())
      assert.equals(1, #quickfix_windows())
      assert.equals(quickfix_windows()[1], result.qf_winnr)
    end)

    it("leaves the window closed by default", function()
      local result = qflist.set_qflist({ items = { stop() } })

      assert.equals(0, #quickfix_windows())
      assert.is_nil(result.qf_winnr)
    end)
  end)

  describe("rejects a route it cannot render", function()
    local function assert_rejects(params, pattern)
      local ok, err = pcall(qflist.set_qflist, params)
      assert.is_false(ok)
      assert.is_truthy(tostring(err):find(pattern))
    end

    it("with no items at all", function()
      assert_rejects({}, "non%-empty")
      assert_rejects({ items = {} }, "non%-empty")
      assert_rejects({ items = "nope" }, "non%-empty")
    end)

    it("with a malformed stop", function()
      assert_rejects({ items = { "not a table" } }, "must be an object")
      assert_rejects({ items = { { lnum = 1 } } }, "filename is required")
      assert_rejects({ items = { { filename = existing_file } } }, "lnum must be a positive integer")
      assert_rejects({ items = { stop({ lnum = 0 }) } }, "lnum must be a positive integer")
      assert_rejects({ items = { stop({ lnum = 1.5 }) } }, "lnum must be a positive integer")
      assert_rejects({ items = { stop({ col = 0 }) } }, "col must be a positive integer")
      assert_rejects({ items = { stop({ text = 42 }) } }, "text must be a string")
    end)

    it("naming a file that is not there", function()
      -- A hallucinated path would otherwise become a quickfix entry that jumps nowhere.
      assert_rejects({ items = { stop({ filename = existing_file .. ".missing" }) } }, "does not exist")
    end)

    it("without clobbering the current list", function()
      vim.fn.setqflist({}, " ", { title = "kept", items = { stop() } })
      pcall(qflist.set_qflist, { items = { stop({ lnum = 0 }) } })
      assert.equals("kept", vim.fn.getqflist({ title = 0 }).title)
    end)

    it("names the offending index so the caller can fix that one stop", function()
      assert_rejects({ items = { stop(), stop({ lnum = 0 }) } }, "items%[2%]")
    end)
  end)
end)
