-- `gd` の前段。固定したいのは「何を処理済みと言うか」で、それが `diff_opener` に回るかを決める。
--
-- 定義ファイルが開けたときと、コマンドだと分かっていて開く先が無いときだけ `true`。
-- カーソル下がコマンド名でなければ `false` を返して差分側に回さないといけない。順序を守らないと
-- `### Modified Files` の中で `gd` が効かなくなる。

local Opener = require("vibing.presentation.chat.modules.command_definition_opener")
local Fs = require("vibing.core.utils.fs")

describe("command_definition_opener.open", function()
  local saved = {}
  local calls
  local base
  local root
  local saved_home
  local buf

  local function stub(name, module)
    saved[name] = saved[name] or { value = package.loaded[name], had = package.loaded[name] ~= nil }
    package.loaded[name] = module
  end

  local function put_cursor_on(line, pattern)
    buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { line })
    vim.api.nvim_win_set_buf(0, buf)
    vim.api.nvim_win_set_cursor(0, { 1, assert(line:find(pattern, 1, true)) - 1 })
    return buf
  end

  before_each(function()
    calls = { opened = {}, notified = {} }
    base = vim.fn.tempname()
    root = base .. "/project"
    Fs.ensure_dir(root)
    saved_home = vim.env.HOME
    vim.env.HOME = base .. "/home"

    stub("vibing.core.utils.file_path", {
      open_file = function(path)
        table.insert(calls.opened, path)
      end,
    })
    stub("vibing.core.utils.notify", {
      info = function(message)
        table.insert(calls.notified, message)
      end,
      -- plugin_dirs は読めないプラグインを見つけると warn を出す。実際に出るかはこのマシンの
      -- `.vibing/plugins/` 次第なので、無いと落ちる形にはしない
      warn = function() end,
      error = function() end,
    })
    stub("vibing.presentation.chat.view", {
      get_chat_buffer = function()
        return {
          get_cwd = function()
            return root
          end,
        }
      end,
    })
    -- 既定は「ビルトインでもない未知の語」。個別のテストで上書きする
    stub("vibing.application.chat.commands", {
      list_all = function()
        return {}
      end,
    })
    stub("vibing.infrastructure.completion.providers.skills", {
      peek_cli_commands = function()
        return {}
      end,
    })
  end)

  after_each(function()
    for name, entry in pairs(saved) do
      package.loaded[name] = entry.had and entry.value or nil
    end
    saved = {}
    vim.env.HOME = saved_home
    vim.fn.delete(base, "rf")
    if buf and vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_delete(buf, { force = true })
    end
  end)

  it("opens the definition file of the command under the cursor", function()
    local path = root .. "/.claude/skills/temp-skill/SKILL.md"
    Fs.ensure_dir(vim.fn.fnamemodify(path, ":h"))
    vim.fn.writefile({ "---", "description: x", "---" }, path)

    local handled = Opener.open(put_cursor_on("try /temp-skill first", "/temp-skill"))

    assert.is_true(handled)
    assert.same({ path }, calls.opened)
    assert.same({}, calls.notified)
  end)

  it("resolves against the chat's own cwd", function()
    -- worktreeに紐づいたチャットは、Neovimのcwdではなく自分の working_dir の `.claude/` を見る
    local path = root .. "/.claude/commands/temp-cmd.md"
    Fs.ensure_dir(vim.fn.fnamemodify(path, ":h"))
    vim.fn.writefile({ "# Temp" }, path)

    assert.is_true(Opener.open(put_cursor_on("/temp-cmd", "/temp-cmd")))
    assert.same({ path }, calls.opened)
  end)

  it("says so, and opens nothing, for a command with no definition file", function()
    stub("vibing.application.chat.commands", {
      list_all = function()
        return { model = { name = "model" } }
      end,
    })

    local handled = Opener.open(put_cursor_on("use /model to switch", "/model"))

    assert.is_true(handled)
    assert.same({}, calls.opened)
    assert.equals(1, #calls.notified)
    assert.is_truthy(calls.notified[1]:match("/model"))
  end)

  it("hands an unknown word back to the diff, silently", function()
    local handled = Opener.open(put_cursor_on("see /not-a-command-xyz here", "/not-a-command"))

    assert.is_false(handled)
    assert.same({}, calls.opened)
    assert.same({}, calls.notified)
  end)

  it("hands a file path back to the diff, even when a segment names a real skill", function()
    -- `### Modified Files` の行で `true` を返すと `gd` の本来の意味が失われる。
    -- パスの途中がたまたま実在するスキル名でも同じなので、そこを陽性対照にする
    for _, name in ipairs({ "vibing", "docs" }) do
      local path = root .. "/.claude/skills/" .. name .. "/SKILL.md"
      Fs.ensure_dir(vim.fn.fnamemodify(path, ":h"))
      vim.fn.writefile({ "---", "description: x", "---" }, path)
    end

    assert.is_false(Opener.open(put_cursor_on("lua/vibing/config.lua", "/vibing")))
    assert.is_false(Opener.open(put_cursor_on("/docs/guide/x.md", "/docs")))
    assert.same({}, calls.opened)
    assert.same({}, calls.notified)
  end)
end)
