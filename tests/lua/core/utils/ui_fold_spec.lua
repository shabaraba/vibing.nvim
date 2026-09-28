---@diagnostic disable: undefined-field
--- Which windows get the fold options, and the two conditions under which none of them do.

describe("ui.apply_fold_config", function()
  local Ui
  local enabled
  local outer_parser
  local chat_buffer

  before_each(function()
    enabled = true
    outer_parser = true
    chat_buffer = true

    package.loaded["vibing.config"] = {
      get = function()
        -- `wrap = "nvim"` so the wrap half of apply_window_config touches nothing here.
        return { ui = { wrap = "nvim", fold = { enabled = enabled } } }
      end,
    }
    package.loaded["vibing.infrastructure.treesitter"] = {
      is_outer_parser_available = function()
        return outer_parser
      end,
    }
    package.loaded["vibing.infrastructure.storage.frontmatter"] = {
      is_vibing_chat_buffer = function()
        return chat_buffer
      end,
    }
    package.loaded["vibing.core.utils.ui"] = nil
    Ui = require("vibing.core.utils.ui")
  end)

  after_each(function()
    for _, module in ipairs({
      "vibing.config",
      "vibing.infrastructure.treesitter",
      "vibing.infrastructure.storage.frontmatter",
      "vibing.core.utils.ui",
    }) do
      package.loaded[module] = nil
    end
  end)

  --- A window whose fold options are all at a value the function must overwrite, so no assertion
  --- below can pass on a leftover.
  local function fresh_window()
    vim.cmd("new")
    local win = vim.api.nvim_get_current_win()
    vim.api.nvim_set_option_value("foldmethod", "manual", { win = win, scope = "local" })
    vim.api.nvim_set_option_value("foldexpr", "0", { win = win, scope = "local" })
    vim.api.nvim_set_option_value("foldlevel", 99, { win = win, scope = "local" })
    vim.api.nvim_set_option_value("foldenable", false, { win = win, scope = "local" })
    return win, vim.api.nvim_get_current_buf()
  end

  local function fold_state(win)
    return {
      foldmethod = vim.api.nvim_get_option_value("foldmethod", { win = win }),
      foldexpr = vim.api.nvim_get_option_value("foldexpr", { win = win }),
      foldlevel = vim.api.nvim_get_option_value("foldlevel", { win = win }),
      foldenable = vim.api.nvim_get_option_value("foldenable", { win = win }),
    }
  end

  local untouched = { foldmethod = "manual", foldexpr = "0", foldlevel = 99, foldenable = false }

  -- Not `vim.treesitter.foldexpr()`: that one applies every injected language's own folds.scm,
  -- which on a chat is markdown's and yaml's. `treesitter_fold_spec.lua` is where that is pinned.
  it("puts a chat window on vibing's own foldexpr with every fold closed", function()
    local win, buf = fresh_window()
    Ui.apply_fold_config(win, buf)
    assert.same({
      foldmethod = "expr",
      foldexpr = require("vibing.infrastructure.treesitter_fold").EXPR,
      foldlevel = 0,
      foldenable = true,
    }, fold_state(win))
    vim.cmd("close")
  end)

  -- `WinEnter` returns to a window that is already configured, so this runs on every switch into a
  -- chat. Re-applying would put `foldlevel` back to 0 -- closing folds the user opened with `zo` --
  -- and setting it sweeps the whole buffer (measured: 19.9ms, one `foldexpr` call per line, on a
  -- 16,805-line chat).
  it("leaves a window it has already configured alone", function()
    local win, buf = fresh_window()
    Ui.apply_fold_config(win, buf)

    vim.api.nvim_set_option_value("foldlevel", 1, { win = win, scope = "local" })
    Ui.apply_fold_config(win, buf)

    assert.equals(1, vim.api.nvim_get_option_value("foldlevel", { win = win }))
    vim.cmd("close")
  end)

  -- The Markdown fallback has none of the nodes folds.scm names, so there would be nothing to fold.
  it("writes nothing when the outer parser is unavailable", function()
    outer_parser = false
    local win, buf = fresh_window()
    Ui.apply_fold_config(win, buf)
    assert.same(untouched, fold_state(win))
    vim.cmd("close")
  end)

  it("writes nothing when folding is turned off", function()
    enabled = false
    local win, buf = fresh_window()
    Ui.apply_fold_config(win, buf)
    assert.same(untouched, fold_state(win))
    vim.cmd("close")
  end)

  it("writes nothing to a window that is not showing a chat", function()
    chat_buffer = false
    local win, buf = fresh_window()
    Ui.apply_fold_config(win, buf)
    assert.same(untouched, fold_state(win))
    vim.cmd("close")
  end)

  it("still writes to a chat buffer that has no frontmatter yet, when forced", function()
    chat_buffer = false
    local win, buf = fresh_window()
    Ui.apply_fold_config(win, buf, true)
    assert.equals("expr", vim.api.nvim_get_option_value("foldmethod", { win = win }))
    vim.cmd("close")
  end)

  -- The one entry point: a setting added to either half has to reach all four places a chat
  -- window is resolved, and they all call this.
  it("is applied by apply_window_config", function()
    local win, buf = fresh_window()
    Ui.apply_window_config(win, buf, true)
    assert.equals("expr", vim.api.nvim_get_option_value("foldmethod", { win = win }))
    vim.cmd("close")
  end)
end)
