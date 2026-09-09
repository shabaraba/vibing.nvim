describe("vibing.infrastructure.treesitter", function()
  local original_add
  local original_register
  local original_start
  local original_eventignore
  local registrations
  local starts

  before_each(function()
    package.loaded["vibing.infrastructure.treesitter"] = nil
    original_add = vim.treesitter.language.add
    original_register = vim.treesitter.language.register
    original_start = vim.treesitter.start
    original_eventignore = vim.o.eventignore
    vim.o.eventignore = "FileType"
    registrations = {}
    starts = {}
    vim.treesitter.language.register = function(lang, filetype)
      registrations[#registrations + 1] = { lang, filetype }
    end
    vim.treesitter.start = function(bufnr, lang)
      starts[#starts + 1] = { bufnr, lang }
    end
  end)

  after_each(function()
    vim.treesitter.language.add = original_add
    vim.treesitter.language.register = original_register
    vim.treesitter.start = original_start
    vim.o.eventignore = original_eventignore
    package.loaded["vibing.infrastructure.treesitter"] = nil
  end)

  it("uses the outer parser when its native library is available", function()
    vim.treesitter.language.add = function(lang)
      assert.equals("vibing", lang)
      return true
    end
    local treesitter = require("vibing.infrastructure.treesitter")

    assert.is_true(treesitter.setup())
    assert.same({ { "vibing", "vibing" } }, registrations)

    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].filetype = "markdown"
    treesitter.apply_filetype(buf)
    assert.equals("vibing", vim.bo[buf].filetype)
    assert.same({ { buf, "vibing" } }, starts)

    -- Reapplying settings after a restart or reattach must restore highlighting even when the
    -- filetype is already correct.
    treesitter.apply_filetype(buf)
    assert.same({ { buf, "vibing" }, { buf, "vibing" } }, starts)
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("falls back to Markdown and preserves markdown filetype when the parser is unavailable", function()
    vim.treesitter.language.add = function()
      return nil, "not installed"
    end
    local treesitter = require("vibing.infrastructure.treesitter")

    assert.is_false(treesitter.setup())
    assert.same({ { "markdown", "vibing" } }, registrations)

    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].filetype = "markdown"
    treesitter.apply_filetype(buf)
    assert.equals("markdown", vim.bo[buf].filetype)
    assert.same({}, starts)
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("treats parser loader errors as a fallback", function()
    vim.treesitter.language.add = function()
      error("bad ABI")
    end
    local treesitter = require("vibing.infrastructure.treesitter")

    assert.is_false(treesitter.setup())
    assert.same({ { "markdown", "vibing" } }, registrations)
  end)
end)
