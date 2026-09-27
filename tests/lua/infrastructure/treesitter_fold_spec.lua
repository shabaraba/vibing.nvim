---@diagnostic disable: undefined-field
--- What a chat window's foldexpr answers, and the one thing it must refuse to look at.
---
--- `vim.treesitter.foldexpr()` walks every tree in the injection stack and runs each injected
--- language's own `folds.scm`. A chat injects markdown, and markdown injects yaml into the
--- frontmatter, so on a real configuration it folded the frontmatter keys, the `##` sections and
--- the prose paragraphs -- 17 fold regions of which only 4 were vibing's. These specs pin that
--- only the outer tree is consulted.

local VibingLanguage = require("tests.helpers.vibing_language")

describe("treesitter_fold.foldexpr", function()
  local Fold

  --- Rows 1..3 are reasoning and rows 7..9 a tool block. Everything else is the answer, the
  --- headings around it, or the markdown a fold query for markdown would happily claim.
  local LINES = {
    "## Assistant", -- 1
    "💭 first thought", -- 2
    "💭", -- 3
    "💭 second thought", -- 4
    "# A heading the markdown grammar owns", -- 5
    "", -- 6
    "- a list item", -- 7
    "⏺ Bash(ls)", -- 8
    "  ⎿  a.txt", -- 9
    "     b.txt", -- 10
    "", -- 11
    "Done.", -- 12
  }

  before_each(function()
    VibingLanguage.ensure()
    package.loaded["vibing.infrastructure.treesitter_fold"] = nil
    Fold = require("vibing.infrastructure.treesitter_fold")
  end)

  --- Put the lines in the current window, since `foldexpr` is asked about the current buffer.
  --- @return integer bufnr
  local function open()
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, LINES)
    vim.api.nvim_set_current_buf(bufnr)
    return bufnr
  end

  --- @return string[] one entry per line, in buffer order
  local function levels()
    local result = {}
    for lnum = 1, #LINES do
      result[lnum] = Fold.foldexpr(lnum)
    end
    return result
  end

  it("folds reasoning and rendered tool calls, and nothing else", function()
    local bufnr = open()

    assert.same({
      "0", -- ## Assistant
      ">1", -- reasoning opens
      "1",
      "1",
      "0", -- the heading is answer content
      "0",
      "0", -- so is the list
      ">1", -- the tool call opens
      "1",
      "1",
      "0",
      "0", -- Done.
    }, levels())

    vim.api.nvim_buf_delete(bufnr, { force = true })
  end)

  -- The regression. Markdown's own fold query is replaced with one that claims every heading
  -- section, which is what the stock foldexpr would apply through the injection; the answer must
  -- not move. Without the positive control below this spec would pass on a query that never ran.
  it("ignores the fold query of an injected language", function()
    vim.treesitter.query.set("markdown", "folds", "(section) @fold")
    local bufnr = open()

    local parser = vim.treesitter.get_parser(bufnr, "vibing")
    parser:parse(true)
    local markdown_folds = 0
    parser:for_each_tree(function(tree, language_tree)
      if language_tree:lang() == "markdown" then
        for _ in vim.treesitter.query.get("markdown", "folds"):iter_captures(tree:root(), bufnr) do
          markdown_folds = markdown_folds + 1
        end
      end
    end)
    assert.is_true(markdown_folds > 0, "the injected fold query must have something to claim")

    assert.equals("0", Fold.foldexpr(5))
    assert.equals("0", Fold.foldexpr(7))
    assert.equals("0", Fold.foldexpr(12))

    vim.api.nvim_buf_delete(bufnr, { force = true })
  end)

  -- Levels are memoized per `changedtick`, which is what keeps a foldexpr off one query pass per
  -- line. A tool block arrives one delta at a time, so a cache that outlived the edit would leave
  -- the block that was being streamed when it was filled permanently unfolded.
  it("re-reads the buffer after it is appended to", function()
    local bufnr = open()
    assert.equals("0", Fold.foldexpr(12))

    vim.api.nvim_buf_set_lines(bufnr, -1, -1, false, { "⏺ Read(a.lua)", "  ⎿  1 line" })

    assert.equals(">1", Fold.foldexpr(13))
    assert.equals("1", Fold.foldexpr(14))

    vim.api.nvim_buf_delete(bufnr, { force = true })
  end)

  --- A turn shaped like the one this behaviour was reported from: two tool calls in a row, then
  --- prose, then a single tool call. The renderer separates tool blocks with a blank line.
  local RUN_LINES = {
    "## Assistant <!-- 2026-09-27 21:19:29 -->", -- 1
    "できます。まず環境に何が入っているか確認します。", -- 2
    "", -- 3
    "💻 Bash(command -v vhs)", -- 4
    "", -- 5
    "💻 Bash(sw_vers -productVersion)", -- 6
    "", -- 7
    "ffmpeg と WezTerm はあり、VHS 系は未導入です。", -- 8
    "", -- 9
    "⏺ ToolSearch(select:nvim_ask_user_question)", -- 10
  }

  it("collapses a run of tool calls into one fold, blank separators and all", function()
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, RUN_LINES)
    vim.api.nvim_set_current_buf(bufnr)

    local result = {}
    for lnum = 1, #RUN_LINES do
      result[lnum] = Fold.foldexpr(lnum)
    end

    assert.same({
      "0", -- ## Assistant
      "0", -- prose
      "0",
      ">1", -- the run opens
      "1", -- the blank line between the two calls is inside it
      "1", -- and so is the second call
      "0", -- the run ends: the blank before prose is not part of it
      "0", -- prose
      "0",
      ">1", -- the lone call after the prose is its own fold
    }, result)

    vim.api.nvim_buf_delete(bufnr, { force = true })
  end)

  it("keeps reasoning out of the tool call it sits against", function()
    local lines = {
      "💭 a thought", -- 1
      "💭 and another", -- 2
      "", -- 3
      "💻 Bash(ls)", -- 4
      "  ⎿  a.txt", -- 5
    }
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    vim.api.nvim_set_current_buf(bufnr)

    -- Merged, the whole thing would read as one tool call and the reasoning would be gone.
    assert.same({ ">1", "1", "0", ">1", "1" }, {
      Fold.foldexpr(1),
      Fold.foldexpr(2),
      Fold.foldexpr(3),
      Fold.foldexpr(4),
      Fold.foldexpr(5),
    })

    vim.api.nvim_buf_delete(bufnr, { force = true })
  end)

  --- The refresh is pinned as the call, not as the symptom it repairs.
  ---
  --- Neovim keeps a fold whose *extent* grew -- a run of tool calls gaining another member -- at
  --- its old end, and reads the rest of the run as ordinary content. That was observed mid-turn on
  --- a live chat (rows 133..140 at level 0 against a tree that said 1, repaired by `setlocal
  --- foldmethod=expr`) and has not been reproduced from a script writing the same bytes, so a spec
  --- asserting the levels would pass with the refresh deleted. `vim.treesitter`'s own fold module
  --- carries the same explicit refresh for the same reason.
  describe("after the buffer changes", function()
    local calls
    local real_foldupdate

    before_each(function()
      calls = {}
      real_foldupdate = vim._foldupdate
      vim._foldupdate = function(win, srow, erow)
        calls[#calls + 1] = { win = win, srow = srow, erow = erow }
        return real_foldupdate and real_foldupdate(win, srow, erow)
      end
    end)

    after_each(function()
      vim._foldupdate = real_foldupdate
    end)

    --- @return integer win, integer bufnr
    local function folded_window()
      vim.cmd("new")
      local bufnr = vim.api.nvim_get_current_buf()
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, RUN_LINES)
      vim.wo.foldexpr = "v:lua.require'vibing.infrastructure.treesitter_fold'.foldexpr(v:lnum)"
      vim.wo.foldmethod = "expr"
      -- The buffer is watched from the first foldexpr Neovim asks for, which the line above has
      -- already triggered; only what happens afterwards is under test.
      calls = {}
      return vim.api.nvim_get_current_win(), bufnr
    end

    it("asks every expr-folded window showing it to re-derive its folds", function()
      local win, bufnr = folded_window()

      vim.api.nvim_buf_set_lines(bufnr, -1, -1, false, { "", "💻 Bash(ls)" })
      vim.wait(200, function()
        return #calls > 0
      end)

      assert.is_true(#calls > 0, "no fold refresh was requested")
      assert.equals(win, calls[1].win)
      assert.equals(0, calls[1].srow)
      assert.equals(vim.api.nvim_buf_line_count(bufnr), calls[1].erow)

      vim.cmd("close")
      vim.api.nvim_buf_delete(bufnr, { force = true })
    end)

    it("coalesces a burst of changes into one refresh", function()
      local _, bufnr = folded_window()

      for index = 1, 8 do
        vim.api.nvim_buf_set_lines(bufnr, -1, -1, false, { "💻 Bash(echo " .. index .. ")" })
      end
      vim.wait(200, function()
        return #calls > 0
      end)

      -- Streaming writes a delta at a time; one refresh per delta would re-derive the folds of the
      -- whole chat dozens of times a second.
      assert.equals(1, #calls)

      vim.cmd("close")
      vim.api.nvim_buf_delete(bufnr, { force = true })
    end)
  end)

  -- What the reader actually sees, which the levels alone do not say: `foldminlines` counts
  -- *screen* lines, so whether a one-line fold is drawn closed depends on `wrap` and the window
  -- width. Both are pinned here, or this would pass or fail by terminal size.
  it("draws the run closed and leaves everything around it open", function()
    vim.cmd("new")
    local bufnr = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, RUN_LINES)
    vim.wo.wrap = false
    vim.wo.foldminlines = 1
    vim.wo.foldexpr = "v:lua.require'vibing.infrastructure.treesitter_fold'.foldexpr(v:lnum)"
    vim.wo.foldmethod = "expr"
    vim.wo.foldlevel = 0
    vim.wo.foldenable = true

    local closed = {}
    for lnum = 1, #RUN_LINES do
      closed[lnum] = vim.fn.foldclosed(lnum)
    end

    -- Lines 4..6 are one closed fold; -1 is "this line is not inside a closed fold".
    assert.same({ -1, -1, -1, 4, 4, 4, -1, -1, -1, -1 }, closed)

    vim.cmd("close")
    vim.api.nvim_buf_delete(bufnr, { force = true })
  end)
end)
