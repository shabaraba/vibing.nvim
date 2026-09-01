local Git = require("vibing.core.utils.git")
local FrontmatterHandler = require("vibing.presentation.chat.modules.frontmatter_handler")
local ChatFiles = require("tests.helpers.chat_files")
local view = require("vibing.presentation.chat.view")

describe("OrchestrationLink.link", function()
  local OrchestrationLink
  local original_get_root, original_get_chat_buffer
  local dir
  local buffers = {}
  local refuse_writes_for = nil

  ---ファイル実体を持つチャットバッファを開き、`view.get_chat_buffer` が返す形に包む
  ---@param name string
  ---@return number bufnr
  local function open_chat(name)
    ChatFiles.write(dir, name, {})
    local bufnr = vim.fn.bufadd(dir .. "/" .. name)
    vim.fn.bufload(bufnr)
    table.insert(buffers, bufnr)
    return bufnr
  end

  ---@param path string
  ---@return table
  local function frontmatter_on_disk(path)
    return ChatFiles.read_frontmatter(path)
  end

  before_each(function()
    original_get_root = Git.get_root
    original_get_chat_buffer = view.get_chat_buffer
    dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    -- `nvim_buf_get_name` はシンボリックリンクを解決した形を返す（macOSでは `/var` が
    -- `/private/var`）。gitルートを未解決のまま渡すと `to_display_path` が「ルート外」と
    -- 判断して絶対パスを書くので、テストの前提から外れる
    dir = vim.fn.resolve(dir)
    buffers = {}
    refuse_writes_for = nil

    Git.get_root = function()
      return dir
    end
    view.get_chat_buffer = function(bufnr)
      if not vim.api.nvim_buf_is_valid(bufnr) then
        return nil
      end
      return {
        update_frontmatter_list = function(_, key, value, action)
          -- frontmatter の閉じ `---` が走査範囲外にあるチャットでは false が返る。
          -- 実際に長い permission 配列で起きるケースを、書き込み拒否として再現する
          if refuse_writes_for == bufnr then
            return false
          end
          return FrontmatterHandler.update_list(bufnr, key, value, action)
        end,
        get_frontmatter_list = function(_, key)
          return FrontmatterHandler.get_list(bufnr, key)
        end,
      }
    end

    package.loaded["vibing.application.chat.orchestration_link"] = nil
    OrchestrationLink = require("vibing.application.chat.orchestration_link")
  end)

  after_each(function()
    Git.get_root = original_get_root
    view.get_chat_buffer = original_get_chat_buffer
    for _, bufnr in ipairs(buffers) do
      if vim.api.nvim_buf_is_valid(bufnr) then
        vim.api.nvim_buf_delete(bufnr, { force = true })
      end
    end
    vim.fn.delete(dir, "rf")
  end)

  it("records both directions and saves both files", function()
    local from, to = open_chat("orchestrator.md"), open_chat("worker.md")

    assert.is_true(OrchestrationLink.link(from, to))

    assert.same({ "worker.md" }, frontmatter_on_disk(dir .. "/orchestrator.md").orchestrated)
    assert.same({ "orchestrator.md" }, frontmatter_on_disk(dir .. "/worker.md").orchestrated_by)
  end)

  it("saves the side that did get written when the other refuses", function()
    -- 片肺でもリネーム同期は書けた側で動く。ここで保存を飛ばすと、書き込みに成功した
    -- バッファが modified のまま一度も保存されない（呼び出し元は警告するだけで続行する）
    local from, to = open_chat("orchestrator.md"), open_chat("worker.md")
    refuse_writes_for = to

    local ok, err = OrchestrationLink.link(from, to)

    assert.is_false(ok)
    assert.is_truthy(err)
    assert.same({ "worker.md" }, frontmatter_on_disk(dir .. "/orchestrator.md").orchestrated)
    assert.is_false(vim.bo[from].modified, "the written side must not be left dirty")
  end)

  it("refuses a chat linking to itself", function()
    local bufnr = open_chat("solo.md")

    assert.is_false(OrchestrationLink.link(bufnr, bufnr))
  end)

  it("does not rewrite when both sides already record the relationship", function()
    local from, to = open_chat("orchestrator.md"), open_chat("worker.md")
    assert.is_true(OrchestrationLink.link(from, to))

    -- 作成と送信の両方で `from_bufnr` が渡るので、同じリンクが2回書かれる経路がある
    assert.is_true(OrchestrationLink.link(from, to))

    assert.same({ "worker.md" }, frontmatter_on_disk(dir .. "/orchestrator.md").orchestrated)
  end)
end)
