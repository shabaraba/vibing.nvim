-- パス → bufnr の変換点。ここが答えを返せないと、再起動を跨いだオーケストレーション網は
-- frontmatter に正しい記録を持ったまま二度と繋がらない（#641）。

local Git = require("vibing.core.utils.git")
local ChatFiles = require("tests.helpers.chat_files")
local view = require("vibing.presentation.chat.view")

describe("ChatLocator.resolve_all", function()
  ---gitルートのキャッシュはモジュールレベルなのでspec間で持ち越す。毎回requireし直して捨てる
  local ChatLocator
  local original_get_root
  local dir
  local buffers = {}

  ---@param name string
  ---@return number bufnr
  local function open_buffer(name)
    local bufnr = vim.fn.bufadd(dir .. "/" .. name)
    vim.fn.bufload(bufnr)
    table.insert(buffers, bufnr)
    return bufnr
  end

  before_each(function()
    original_get_root = Git.get_root
    dir = vim.fn.resolve(vim.fn.tempname())
    vim.fn.mkdir(dir, "p")
    buffers = {}

    package.loaded["vibing.application.chat.chat_locator"] = nil
    ChatLocator = require("vibing.application.chat.chat_locator")
  end)

  after_each(function()
    Git.get_root = original_get_root
    for _, bufnr in ipairs(buffers) do
      if vim.api.nvim_buf_is_valid(bufnr) then
        vim.api.nvim_buf_delete(bufnr, { force = true })
      end
    end
    vim.fn.delete(dir, "rf")
  end)

  it("resolves a git-root-relative path to the open buffer", function()
    Git.get_root = function()
      return dir
    end
    local bufnr = open_buffer("worker.md")

    assert.same({ { path = "worker.md", bufnr = bufnr } }, ChatLocator.resolve_all({ "worker.md" }))
  end)

  it("accepts the hand-written scalar form", function()
    Git.get_root = function()
      return dir
    end
    local bufnr = open_buffer("worker.md")

    assert.same({ { path = "worker.md", bufnr = bufnr } }, ChatLocator.resolve_all("worker.md"))
  end)

  it("keeps a path that is not open, with no bufnr", function()
    -- `resolve_bufnrs` はここで要素ごと落としていた。落とすと、閉じているオーケストレーターを
    -- 持つワーカーはシステムプロンプトの行を丸ごと失い、パスで呼び戻すこともできなくなる
    Git.get_root = function()
      return dir
    end

    assert.same({ { path = "worker.md" } }, ChatLocator.resolve_all({ "worker.md" }))
  end)

  it("returns nothing for an absent or empty list", function()
    assert.same({}, ChatLocator.resolve_all(nil))
    assert.same({}, ChatLocator.resolve_all({}))
  end)

  it("re-resolves the git root after a directory becomes a repository", function()
    -- 「gitではない」をキャッシュすると、あとから git init された（あるいはworktreeが生えた）
    -- ディレクトリが永久に誤判定のままになり、`orchestrated_by` の解決が黙って空を返し続ける。
    -- pcall で握りつぶされるので、エラーにもならず気づけない
    local calls = 0
    Git.get_root = function()
      calls = calls + 1
      return nil
    end
    local bufnr = open_buffer("worker.md")

    assert.is_nil(ChatLocator.resolve_all({ "worker.md" })[1].bufnr)

    Git.get_root = function()
      calls = calls + 1
      return dir
    end

    assert.equals(bufnr, ChatLocator.resolve_all({ "worker.md" })[1].bufnr)
    assert.equals(2, calls, "a failed lookup must not be remembered")
  end)

  it("caches a successful lookup instead of spawning git per send", function()
    local calls = 0
    Git.get_root = function()
      calls = calls + 1
      return dir
    end
    open_buffer("worker.md")

    ChatLocator.resolve_all({ "worker.md" })
    ChatLocator.resolve_all({ "worker.md" })
    ChatLocator.resolve_all({ "worker.md" })

    assert.equals(1, calls)
  end)
end)

describe("ChatLocator.open", function()
  local ChatLocator
  local original_get_root, original_attach
  local dir
  local buffers = {}
  local attached = {}

  before_each(function()
    original_get_root = Git.get_root
    original_attach = view.attach_to_buffer
    dir = vim.fn.resolve(vim.fn.tempname())
    vim.fn.mkdir(dir, "p")
    buffers = {}
    attached = {}

    Git.get_root = function()
      return dir
    end
    -- アタッチはキーマップとautocmdを張る presentation の仕事で、このspecの主題ではない。
    -- 「アタッチされたか」だけ観測する
    view.attach_to_buffer = function(bufnr)
      attached[bufnr] = true
      return { buf = bufnr }
    end

    package.loaded["vibing.application.chat.chat_locator"] = nil
    ChatLocator = require("vibing.application.chat.chat_locator")
  end)

  after_each(function()
    Git.get_root = original_get_root
    view.attach_to_buffer = original_attach
    for _, bufnr in ipairs(buffers) do
      if vim.api.nvim_buf_is_valid(bufnr) then
        vim.api.nvim_buf_delete(bufnr, { force = true })
      end
    end
    vim.fn.delete(dir, "rf")
  end)

  ---@param bufnr number
  local function track(bufnr)
    table.insert(buffers, bufnr)
    return bufnr
  end

  it("opens a chat file that has no buffer yet", function()
    ChatFiles.write(dir, "worker.md", {})

    local bufnr = track(ChatLocator.open("worker.md"))

    assert.is_true(vim.api.nvim_buf_is_loaded(bufnr))
    assert.is_true(attached[bufnr])
    -- 開いたチャットが `:ls` に出ないと、ユーザーはそれを読むことも閉じることもできない
    assert.is_true(vim.bo[bufnr].buflisted)
  end)

  it("reuses the buffer a chat file already has", function()
    ChatFiles.write(dir, "worker.md", {})
    local existing = track(vim.fn.bufadd(dir .. "/worker.md"))
    vim.fn.bufload(existing)

    assert.equals(existing, ChatLocator.open("worker.md"))
  end)

  it("lists a buffer someone else opened unlisted", function()
    -- `vim.fn.bufadd` makes an **unlisted** buffer, and `auto_resume` / `nvim_dap` both use it.
    -- Reusing one without listing it leaves the model driving a chat the user cannot see in `:ls`
    ChatFiles.write(dir, "worker.md", {})
    local existing = track(vim.fn.bufadd(dir .. "/worker.md"))
    vim.fn.bufload(existing)
    assert.is_false(vim.bo[existing].buflisted, "precondition: bufadd leaves it unlisted")

    ChatLocator.open("worker.md")

    assert.is_true(vim.bo[existing].buflisted)
  end)

  it("accepts an absolute path as well as a git-root-relative one", function()
    ChatFiles.write(dir, "worker.md", {})

    local by_relative = track(ChatLocator.open("worker.md"))
    assert.equals(by_relative, ChatLocator.open(dir .. "/worker.md"))
  end)

  it("refuses a file that is not a chat, and creates no buffer for it", function()
    local path = dir .. "/notes.md"
    vim.fn.writefile({ "# just a file" }, path)

    assert.has_error(function()
      ChatLocator.open("notes.md")
    end)
    -- 断った呼び出しが無関係なバッファを残していかない
    assert.equals(-1, vim.fn.bufnr(path))
  end)

  it("refuses a path with no file behind it", function()
    assert.has_error(function()
      ChatLocator.open("gone.md")
    end)
  end)

  it("refuses an empty file_path rather than resolving it to the cwd", function()
    assert.has_error(function()
      ChatLocator.open("")
    end)
  end)
end)
