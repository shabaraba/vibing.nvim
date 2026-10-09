-- 複数選択したチャットの開き方: 表示は先頭の1つだけで、残りは `:bnext` で辿れるチャット
-- バッファとして読み込むだけ。見せないほうも `attach_to_buffer` を通さないと、ただの Markdown
-- になってキーマップが付かない。
--
-- 「そのファイルのバッファが既にあるなら作り直さない」は `view.render` 側の仕事で、
-- `view_existing_buffer_spec.lua` が見ている。
local ChatOpener = require("vibing.presentation.chat.modules.chat_opener")

---@return string
local function write_file(name)
  local path = vim.fn.tempname() .. "_" .. name .. ".md"
  vim.fn.writefile({ "---", "vibing.nvim: true", "---", "", "## User", "", "hi" }, path)
  return path
end

describe("chat opener", function()
  local rendered
  local attached
  local unloadable

  before_each(function()
    rendered, attached, unloadable = {}, {}, {}

    package.loaded["vibing.presentation.chat.view"] = {
      render = function(session)
        table.insert(rendered, session)
      end,
      attach_to_buffer = function(bufnr, path)
        table.insert(attached, { bufnr = bufnr, path = path })
      end,
    }
    package.loaded["vibing.application.chat.use_case"] = {
      open_file = function(path)
        if unloadable[path] then
          return nil
        end
        return { file_path = path }
      end,
    }
  end)

  after_each(function()
    package.loaded["vibing.presentation.chat.view"] = nil
    package.loaded["vibing.application.chat.use_case"] = nil
  end)

  it("displays the first chat and only the first", function()
    local first, second, third = write_file("a"), write_file("b"), write_file("c")

    assert.are.equal(3, ChatOpener.open_all({ first, second, third }))
    assert.are.equal(1, #rendered)
    assert.are.equal(first, rendered[1].file_path)
  end)

  it("attaches the ones it does not display, loaded and listed", function()
    local first, second = write_file("a"), write_file("b")

    ChatOpener.open_all({ first, second })

    assert.are.equal(1, #attached)
    assert.are.equal(second, attached[1].path)
    assert.is_true(vim.api.nvim_buf_is_loaded(attached[1].bufnr))
    assert.is_true(vim.bo[attached[1].bufnr].buflisted)
  end)

  it("gives the displayed slot to the next chat when the first will not load", function()
    local first, second = write_file("a"), write_file("b")
    unloadable[first] = true

    assert.are.equal(1, ChatOpener.open_all({ first, second }))
    assert.are.equal(1, #rendered)
    assert.are.equal(second, rendered[1].file_path)
    assert.are.same({}, attached)
  end)

  it("opens nothing when handed nothing", function()
    assert.are.equal(0, ChatOpener.open_all(nil))
    assert.are.equal(0, ChatOpener.open_all({}))
  end)
end)
