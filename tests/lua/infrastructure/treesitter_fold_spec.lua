---@diagnostic disable: undefined-field
--- What a chat window's foldexpr answers, the one thing it must refuse to look at, and when it is
--- allowed to look at all.
---
--- `vim.treesitter.foldexpr()` walks every tree in the injection stack and runs each injected
--- language's own `folds.scm`. A chat injects markdown, and markdown injects yaml into the
--- frontmatter, so on a real configuration it folded the frontmatter keys, the `##` sections and
--- the prose paragraphs -- 17 fold regions of which only 4 were vibing's. These specs pin that
--- only the outer tree is consulted, and that it is consulted when a turn ends rather than on
--- every chunk the turn streams.

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

  -- Reported from a turn that ran a script through `Bash`: everything from the script's own first
  -- `foo(x)` onwards stayed open, because the rule that found the end of a multi-line call was
  -- written as "the first line ending in `)`". Where the call ends is where its parentheses close.
  it("folds a tool call whose argument is a whole script", function()
    local lines = {
      '💻 Bash(cd /tmp && nvim --headless -u NONE -c "', -- 1
      "set foldmethod=manual", -- 2
      "call setline(1, ['---'] + map(range(2,19), 'k'))", -- 3
      "1,17fold",
      "echo 'after first fold: end=' . foldclosedend(1)",
      "qa!",
      '" 2>&1)', -- 7
      "", -- 8
      "答え。", -- 9
    }
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    vim.api.nvim_set_current_buf(bufnr)

    local result = {}
    for lnum = 1, #lines do
      result[lnum] = Fold.foldexpr(lnum)
    end

    assert.same({ ">1", "1", "1", "1", "1", "1", "1", "0", "0" }, result)

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

  --- When the folds are derived, which is the whole cost of this feature.
  ---
  --- A turn arrives one 50ms chunk at a time, and the run a chunk lands in is not finished until
  --- the turn is. Deriving per chunk re-read the whole chat 20 times a second to draw a fold that
  --- was about to change again -- 13.4 ms a flush on the 21471-line chat in this repository, a
  --- quarter of the main loop. So a streaming turn derives nothing and `VibingResponseDone` folds
  --- the lot in one pass.
  describe("when a turn ends", function()
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
      -- Neovim evaluates the new foldexpr on its next redraw, which headless never does. A chat
      -- has been derived once before a turn starts, so put the buffer in that state; only what
      -- happens afterwards is under test.
      Fold.foldexpr(1)
      calls = {}
      return vim.api.nvim_get_current_win(), bufnr
    end

    local function finish_turn(bufnr)
      vim.api.nvim_exec_autocmds("User", {
        pattern = "VibingResponseDone",
        data = { bufnr = bufnr },
      })
    end

    local function close(bufnr)
      vim.cmd("close")
      vim.api.nvim_buf_delete(bufnr, { force = true })
    end

    it("leaves what the turn is still writing unfolded, and folds it once the turn ends", function()
      local _, bufnr = folded_window()

      vim.api.nvim_buf_set_lines(bufnr, -1, -1, false, {
        "", -- 11
        "続けます。", -- 12
        "", -- 13
        "💻 Bash(ls)", -- 14
        "  ⎿  ok", -- 15
      })
      assert.equals("0", Fold.foldexpr(14))
      assert.equals("0", Fold.foldexpr(15))

      finish_turn(bufnr)

      assert.equals(">1", Fold.foldexpr(14))
      assert.equals("1", Fold.foldexpr(15))
      -- The run the turn started above is untouched by the one it ended with.
      assert.equals(">1", Fold.foldexpr(10))

      close(bufnr)
    end)

    -- Neovim does not re-evaluate `foldexpr` for lines it did not itself change, and a finished
    -- turn moves the *extent* of folds whose opening row never changed. `vim.treesitter`'s own
    -- fold module carries the same explicit refresh for the same reason.
    it("asks every expr-folded window showing it to re-derive", function()
      local win, bufnr = folded_window()

      vim.api.nvim_buf_set_lines(bufnr, -1, -1, false, { "", "💻 Bash(ls)" })
      finish_turn(bufnr)

      assert.equals(1, #calls)
      assert.same(
        { win = win, srow = 0, erow = vim.api.nvim_buf_line_count(bufnr) },
        { win = calls[1].win, srow = calls[1].srow, erow = calls[1].erow }
      )

      close(bufnr)
    end)

    it("derives nothing at all while the turn appends below the folds", function()
      local _, bufnr = folded_window()

      local real_get = vim.treesitter.query.get
      local derivations = 0
      vim.treesitter.query.get = function(lang, name, ...)
        if lang == "vibing" and name == "folds" then
          derivations = derivations + 1
        end
        return real_get(lang, name, ...)
      end

      local ok, err = pcall(function()
        for index = 1, 8 do
          vim.api.nvim_buf_set_lines(bufnr, -1, -1, false, { "💻 Bash(echo " .. index .. ")" })
          Fold.foldexpr(vim.api.nvim_buf_line_count(bufnr))
        end
      end)
      vim.treesitter.query.get = real_get
      assert.is_true(ok, tostring(err))

      assert.equals(0, derivations)
      assert.equals(0, #calls)

      close(bufnr)
    end)

    -- The other half of that bargain: an edit the user makes inside the folded part *does* move
    -- the regions, and serving the cache there would leave the folds pointing at the wrong rows
    -- with no way to recover short of starting a turn.
    it("re-derives after an edit that reaches into what is already folded", function()
      local _, bufnr = folded_window()

      -- Rows 3..5 are the run of two calls; this turns the second of them into prose.
      vim.api.nvim_buf_set_lines(bufnr, 5, 6, false, { "ただの文章。" })

      assert.same({ ">1", "0", "0" }, { Fold.foldexpr(4), Fold.foldexpr(5), Fold.foldexpr(6) })

      close(bufnr)
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
