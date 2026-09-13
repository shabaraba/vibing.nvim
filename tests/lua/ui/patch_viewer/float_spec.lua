-- patch_viewer のフロートは Files / Before / After の3ペイン。Afterに出るのは **実ファイルの
-- バッファ** で、両ペインを組み込みのdiffモードに入れている。
--
-- ここで固定したいのは、そのAfterペインが実ファイルであることの代償が漏れないこと:
--   * ビューア用のキーは実ファイルのバッファに焼かれるので、閉じる時に外さないと `q` を奪う
--   * `diff` はウィンドウローカルなので、閉じればファイル側に痕跡が残らない
--   * このビューアが作ったスクラッチだけを消す（実ファイルを消してはいけない）
local PatchViewer = require("vibing.ui.patch_viewer")
local state = require("vibing.ui.patch_viewer.state")

describe("patch_viewer float", function()
  local repo
  local patch_path

  local function git(...)
    local result = vim.system({ "git", ... }, { cwd = repo, text = true }):wait()
    return result
  end

  ---macOSの `/var` → `/private/var` のように、バッファ名はシンボリックリンク解決後になる
  local function same_file(path, buf)
    assert.equals(vim.fn.resolve(path), vim.fn.resolve(vim.api.nvim_buf_get_name(buf)))
  end

  ---side-by-side を前提にするテストの入口。選んだ表示形式はモジュールローカルに残り、
  ---`_close` でも消えないので、素の `show` は直前のテストが何を選んだかに左右される
  local function open_split()
    PatchViewer.show("sess", patch_path, nil)
    if state.layout ~= "split" then
      PatchViewer._toggle_layout()
    end
  end

  local saved_columns

  before_each(function()
    -- 一覧のファイル名は幅が足りなければ詰められる。80桁のままだと20%幅が14桁しかなく、
    -- アイコンの有無で結果が変わってしまう
    saved_columns = vim.o.columns
    vim.o.columns = 200

    repo = vim.fn.tempname()
    vim.fn.mkdir(repo .. "/.vibing/patches", "p")
    repo = vim.fn.fnamemodify(repo, ":p"):gsub("/$", "")
    git("init", "-q")
    git("config", "user.email", "test@example.com")
    git("config", "user.name", "test")

    vim.fn.writefile({ "one", "two", "three" }, repo .. "/a.txt")
    vim.fn.writefile({ "alpha", "beta" }, repo .. "/b.txt")
    git("add", ".")
    git("commit", "-q", "-m", "init")
    vim.fn.writefile({ "one", "TWO", "three", "four" }, repo .. "/a.txt")
    vim.fn.writefile({ "alpha", "BETA" }, repo .. "/b.txt")

    patch_path = repo .. "/.vibing/patches/test.patch"
    local body = "# vibing-request-diff base: " .. repo .. "\n" .. (git("diff").stdout or "")
    vim.fn.writefile(vim.split(body, "\n", { plain = true }), patch_path)
  end)

  after_each(function()
    PatchViewer._close()
    vim.fn.delete(repo, "rf")
    vim.o.columns = saved_columns
  end)

  it("opens three floats and puts the two diff panes in diff mode", function()
    open_split()

    for _, win in ipairs({ state.win_files, state.win_before, state.win_after }) do
      assert.is_true(vim.api.nvim_win_is_valid(win))
      assert.is_not.equals("", vim.api.nvim_win_get_config(win).relative)
    end
    assert.is_true(vim.wo[state.win_before].diff)
    assert.is_true(vim.wo[state.win_after].diff)
  end)

  it("shows the pre-turn text on the left and the real file on the right", function()
    open_split()

    assert.same({ "one", "two", "three" }, vim.api.nvim_buf_get_lines(state.buf_before, 0, -1, false))
    same_file(repo .. "/a.txt", state.buf_after)
    -- 実ファイルなので `nofile` ではない。ここが崩れると `do` も編集も効かない
    assert.equals("", vim.bo[state.buf_after].buftype)
  end)

  it("swaps both panes when another file is selected", function()
    open_split()
    PatchViewer._select_file(1)

    same_file(repo .. "/b.txt", state.buf_after)
    assert.same({ "alpha", "beta" }, vim.api.nvim_buf_get_lines(state.buf_before, 0, -1, false))
  end)

  it("takes its keymaps back off the real file when it closes", function()
    open_split()
    local real_buf = state.buf_after
    assert.is_true(#vim.api.nvim_buf_get_keymap(real_buf, "n") > 0)

    PatchViewer._close()

    assert.equals(0, #vim.api.nvim_buf_get_keymap(real_buf, "n"))
    -- 実ファイルのバッファ自体は消さない。消すと開いていたウィンドウごと巻き込む
    assert.is_true(vim.api.nvim_buf_is_valid(real_buf))
  end)

  it("gives the real file back the mappings it already had", function()
    -- ftpluginやユーザー定義が `q` / `s` を使っていることはある。ビューアはそれを上書きして
    -- 閉じる時に消すので、控えて戻さないとフロートを閉じた後も消えたままになる
    local real_buf = vim.fn.bufadd(repo .. "/a.txt")
    vim.fn.bufload(real_buf)
    vim.keymap.set("n", "q", "<Cmd>echo 'mine'<CR>", { buffer = real_buf, desc = "user" })

    open_split()
    assert.equals(real_buf, state.buf_after)

    PatchViewer._close()

    local maps = vim.api.nvim_buf_get_keymap(real_buf, "n")
    assert.equals(1, #maps)
    assert.equals("q", maps[1].lhs)
    assert.equals("user", maps[1].desc)
  end)

  it("lists each file with its own change counts", function()
    open_split()

    local lines = vim.api.nvim_buf_get_lines(state.buf_files, 0, -1, false)
    -- 先頭2行がヘッダなのは固定。`_select_file` のカーソル移動がこの位置に依存している
    assert.is_truthy(lines[1]:find("Files (2)", 1, true))
    assert.equals("", lines[2])
    assert.is_truthy(lines[3]:find("▎", 1, true))
    assert.is_truthy(lines[3]:find("a.txt", 1, true))
    assert.is_truthy(lines[3]:find("+2 -1", 1, true))
    assert.is_falsy(lines[4]:find("▎", 1, true))
    assert.is_truthy(lines[4]:find("+1 -1", 1, true))
  end)

  it("puts diffopt back the way it found it", function()
    -- グローバルオプションなので、閉じた後も残っていると他の `:diffthis` に効いてしまう
    local original = vim.o.diffopt

    open_split()
    assert.is_truthy(vim.o.diffopt:find("linematch:60", 1, true))

    PatchViewer._close()
    assert.equals(original, vim.o.diffopt)
  end)

  it("drops the Before pane and widens the diff when it switches to unified", function()
    open_split()
    local split_width = vim.api.nvim_win_get_width(state.win_after)

    PatchViewer._toggle_layout()

    assert.equals("unified", state.layout)
    assert.is_nil(state.win_before)
    -- 統一diffはdiffモードではなくテキスト1枚
    assert.is_false(vim.wo[state.win_after].diff)
    assert.is_true(vim.api.nvim_win_get_width(state.win_after) > split_width)

    -- 行頭の `+` / `-` はサイン列へ移してあり、バッファには素のコードだけが入る。
    -- 残っていると、その行はもうその言語として壊れていて構文ハイライトが当たらない
    assert.equals("text", vim.bo[state.buf_after].filetype)
    assert.same(
      { "@@ -1,3 +1,4 @@", "one", "two", "TWO", "three", "four" },
      vim.api.nvim_buf_get_lines(state.buf_after, 0, -1, false)
    )
    assert.is_truthy(vim.wo[state.win_after].statuscolumn:find("statuscolumn()", 1, true))
  end)

  it("puts the window's own gutter back when it leaves unified", function()
    open_split()
    PatchViewer._toggle_layout()
    PatchViewer._toggle_layout()

    -- side-by-side は行番号も折り畳み列も要る。戻し忘れると実ファイルの上に
    -- 統一diffの行番号が出たままになる
    assert.equals("", vim.wo[state.win_after].statuscolumn)
  end)

  it("puts the real file back when it switches to side-by-side again", function()
    open_split()
    PatchViewer._toggle_layout()
    PatchViewer._toggle_layout()

    assert.equals("split", state.layout)
    assert.is_true(vim.api.nvim_win_is_valid(state.win_before))
    assert.is_true(vim.wo[state.win_after].diff)
    assert.equals("", vim.bo[state.buf_after].buftype)
    same_file(repo .. "/a.txt", state.buf_after)
  end)

  it("leaves the file with no diff state after closing", function()
    open_split()
    local real_buf = state.buf_after
    PatchViewer._close()

    vim.cmd.edit(vim.fn.fnameescape(repo .. "/a.txt"))
    assert.equals(real_buf, vim.api.nvim_get_current_buf())
    assert.is_false(vim.wo[0].diff)
  end)

  -- この選択はモジュールローカルに残るので、必ず最後に置いて "split" に戻してから終わる
  it("remembers the chosen layout for the next time the float opens", function()
    open_split()
    PatchViewer._toggle_layout()
    PatchViewer._close()

    -- ここは素の `show`。覚えているかどうかを見るのだから正規化してはいけない
    PatchViewer.show("sess", patch_path, nil)
    assert.equals("unified", state.layout)

    PatchViewer._toggle_layout()
    assert.equals("split", state.layout)
  end)
end)
