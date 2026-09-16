-- 進捗フロートの契約。押さえたいのは:
--   * 対象が木のまま1行ずつ並ぶこと（件数だけでは何が対象になったのか分からない）
--   * フォーカスを奪わないこと（奪うと、待っているあいだ他の編集ができない）
--   * 何度動かしても箱は1つで、中身が書き換わること（通知と違って積み上がらないのが存在理由）
--   * finish のあと自分で消え、タイマーを残さないこと
--   * ユーザーが閉じたら開き直さないこと

local progress = require("vibing.presentation.common.progress")

describe("progress float", function()
  local handle

  ---フロートを1つ開いて `handle` に持たせる（after_each が閉じる）
  ---@param labels_by_depth table[] `{label, depth}` の並び
  ---@param opts table? `title` と `linger_ms` の上書き
  ---@return Vibing.Progress.Handle
  local function open(labels_by_depth, opts)
    local items = {}
    for _, pair in ipairs(labels_by_depth) do
      table.insert(items, { label = pair[1], depth = pair[2] })
    end
    handle = progress.open(vim.tbl_extend("keep", opts or {}, { title = "T", items = items }))
    return handle
  end

  ---@return string[]
  local function lines()
    return vim.api.nvim_buf_get_lines(handle._buf, 0, -1, false)
  end

  ---行頭のステータス記号（`sub` はバイト単位なので文字単位で数える）
  ---@param line string
  ---@return string
  local function glyph(line)
    return vim.fn.strcharpart(line, 0, 1)
  end

  ---行頭のステータス列を外し、罫線と名前だけにする
  ---@return string[]
  local function body()
    return vim.tbl_map(function(line)
      return vim.fn.strcharpart(line, 2)
    end, lines())
  end

  after_each(function()
    if handle then
      handle:close()
      handle = nil
    end
  end)

  it("draws the targets as a tree, one line each", function()
    open({
      { "origin.md", 0 },
      { "worker-a.md", 1 },
      { "grand.md", 2 },
      { "worker-b.md", 1 },
    })

    assert.same({
      "origin.md",
      "├─ worker-a.md",
      "│  └─ grand.md",
      "└─ worker-b.md",
    }, body())
  end)

  it("closes a branch with └─ only on its last sibling, whatever follows underneath", function()
    -- 兄弟がまだ下にいるかは、自分より浅い深さが出るまでに同じ深さが再び出るかで決まる。
    -- 「次の行の深さ」で判定する実装だと、孫を挟んだ兄弟のところで罫線が切れる
    open({
      { "root", 0 },
      { "a", 1 },
      { "a-child", 2 },
      { "a-grandchild", 3 },
      { "b", 1 },
    })

    assert.same({
      "root",
      "├─ a",
      "│  └─ a-child",
      "│     └─ a-grandchild",
      "└─ b",
    }, body())
  end)

  it("treats an item with no depth as a root, so a flat list needs no depths", function()
    handle = progress.open({ title = "T", items = { { label = "a.md" }, { label = "b.md" } } })

    assert.same({ "a.md", "b.md" }, body())
  end)

  it("does not take focus", function()
    local before = vim.api.nvim_get_current_win()

    open({ { "a.md", 0 } })

    assert.equals(before, vim.api.nvim_get_current_win())
    assert.is_true(vim.api.nvim_win_is_valid(handle._win))
  end)

  it("rewrites one box, turning each line's marker from running to settled", function()
    open({ { "a.md", 0 }, { "b.md", 1 }, { "c.md", 1 } })

    handle:start(1)
    handle:mark(1, true)
    handle:start(2)
    handle:mark(2, false)
    handle:start(3)

    local drawn = lines()
    assert.equals(3, #drawn)
    assert.equals("✓", glyph(drawn[1]))
    assert.equals("✗", glyph(drawn[2]))
    -- 3件目は実行中。済んだ印でも未着手の空白でもなく、スピナーのどれかが出ている
    assert.is_false(vim.tbl_contains({ "✓", "✗", " " }, glyph(drawn[3])))
  end)

  it("swaps a line's name when the chat behind it is renamed", function()
    open({ { "chat-0001.md", 0 }, { "chat-0002.md", 1 } })

    handle:relabel(2, "fix-the-login-bug.md")

    assert.same({ "chat-0001.md", "└─ fix-the-login-bug.md" }, body())
  end)

  it("widens for a longer name but never narrows again", function()
    -- 1件ごとに枠が踊ると、肝心の中身が読みづらくなる
    open({ { "a.md", 0 }, { "b.md", 1 } })

    handle:relabel(1, string.rep("w", 50) .. ".md")
    local widened = vim.api.nvim_win_get_width(handle._win)
    assert.is_true(widened > 30)

    handle:relabel(1, "short.md")

    assert.equals(widened, vim.api.nvim_win_get_width(handle._win))
  end)

  it("counts settled chats in the border title", function()
    open({ { "a.md", 0 }, { "b.md", 1 } }, { title = "Linked Chats" })

    handle:mark(1, true)

    local title = vim.api.nvim_win_get_config(handle._win).title
    assert.equals(" Linked Chats 1/2 ", title[1][1])
  end)

  it("does not double-count a line that is marked twice", function()
    -- 件数は `_status` から数える。`mark` 側で足し込むと、2度目で総数を超える
    open({ { "a.md", 0 }, { "b.md", 1 } }, { title = "Linked Chats" })

    handle:mark(1, true)
    handle:mark(1, false)

    assert.equals(" Linked Chats 1/2 ", vim.api.nvim_win_get_config(handle._win).title[1][1])
  end)

  it("truncates a name too long for the box rather than widening it", function()
    open({ { string.rep("x", 300) .. ".md", 0 } })
    local width = vim.api.nvim_win_get_width(handle._win)

    assert.is_true(vim.fn.strdisplaywidth(lines()[1]) <= width)
    assert.is_truthy(lines()[1]:find("…", 1, true))
  end)

  it("scrolls so the running chat stays visible when the tree does not fit", function()
    local many = {}
    for i = 1, 60 do
      table.insert(many, { ("chat-%02d.md"):format(i), i == 1 and 0 or 1 })
    end
    open(many)

    handle:start(50)

    local drawn = lines()
    assert.is_true(#drawn < 60)
    assert.is_truthy(table.concat(drawn, "\n"):find("chat-50.md", 1, true))
  end)

  it("shows the finishing message, then closes itself and stops the spinner", function()
    open({ { "a.md", 0 }, { "b.md", 1 } }, { linger_ms = 20 })
    local win = handle._win

    handle:mark(1, true)
    handle:mark(2, true)
    handle:finish("Done: 2 updated, 0 failed")

    assert.is_nil(handle._timer)
    -- 完了の行は木に足される。上書きすると最後の1件だけ結果が読めないまま消える
    assert.equals(3, #lines())
    assert.equals("✓", glyph(lines()[2]))
    assert.equals("Done: 2 updated, 0 failed", lines()[3])

    vim.wait(500, function()
      return not vim.api.nvim_win_is_valid(win)
    end)
    assert.is_false(vim.api.nvim_win_is_valid(win))
  end)

  it("stops the spinner when the buffer is wiped without close", function()
    open({ { "a.md", 0 } })
    handle:start(1)
    assert.is_not_nil(handle._timer)

    vim.api.nvim_buf_delete(handle._buf, { force = true })

    vim.wait(500, function()
      return handle._timer == nil
    end)
    assert.is_nil(handle._timer)
  end)

  it("does not reopen a window the user closed", function()
    open({ { "a.md", 0 }, { "b.md", 1 } })
    local win = handle._win

    -- `:only` などで閉じられた状況。進捗はこの操作の付属物なので、閉じる指示を上書きしない
    vim.api.nvim_win_close(win, true)

    handle:start(2)

    assert.is_false(vim.api.nvim_win_is_valid(win))
    assert.is_nil(vim.fn.win_findbuf(handle._buf or -1)[1])
  end)

  it("shrinks back inside a terminal that got narrower mid-run", function()
    -- 寸法を開いたときのまま描き続けると、狭くなった画面では枠がはみ出して
    -- `nvim_win_set_config` に拒まれる
    local columns, lines_before = vim.o.columns, vim.o.lines
    open({ { "a.md", 0 }, { "b.md", 1 }, { "c.md", 1 }, { "d.md", 1 } })

    vim.o.columns = 34
    vim.o.lines = 8
    handle:start(1)

    assert.is_true(vim.api.nvim_win_get_width(handle._win) <= vim.o.columns - 4)
    assert.is_true(vim.api.nvim_win_get_height(handle._win) <= vim.o.lines)

    vim.o.columns, vim.o.lines = columns, lines_before
  end)

  it("folds itself away when the caller stops reporting progress", function()
    -- 逐次実行はコールバックの鎖で、途中の例外は通知に落とされて鎖がそこで止まる。
    -- `finish` は来ないので、回りっぱなしの箱が画面に残り続けることになる
    open({ { "a.md", 0 }, { "b.md", 1 } }, { stall_ms = 30 })
    local win = handle._win

    handle:start(1)
    -- ここで呼び出し側が死んだ。以降 mark も finish も来ない

    vim.wait(1000, function()
      return not vim.api.nvim_win_is_valid(win)
    end)
    assert.is_false(vim.api.nvim_win_is_valid(win))
    assert.is_nil(handle._timer)
  end)

  it("opens with a usable height even for an empty list", function()
    -- `nvim_open_win` は `height = 0` を受け付けない。0件を弾くのは呼び出し側の都合で、
    -- 部品としてここが落ちてよい理由にはならない
    assert.has_no.errors(function()
      handle = progress.open({ title = "T", items = {} })
    end)
    assert.is_true(vim.api.nvim_win_is_valid(handle._win))
  end)

  it("can be closed twice", function()
    open({ { "a.md", 0 } })

    handle:close()
    assert.has_no.errors(function()
      handle:close()
    end)
  end)
end)
