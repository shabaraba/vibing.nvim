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

  it("does not record the reverse direction when the worker reports back", function()
    -- 押し出し型の報告（#643）は、配布とは逆向きの `nvim_chat_send_message` として届く。
    -- そのまま書くと親の `orchestrated_by` に自分のワーカーが入り、システムプロンプトが
    -- 親に「終わったら自分のワーカーに報告しろ」と指示するようになる
    local orchestrator, worker = open_chat("orchestrator.md"), open_chat("worker.md")
    assert.is_true(OrchestrationLink.link(orchestrator, worker))

    assert.is_true(OrchestrationLink.link(worker, orchestrator))

    local on_orchestrator = frontmatter_on_disk(dir .. "/orchestrator.md")
    local on_worker = frontmatter_on_disk(dir .. "/worker.md")
    assert.same({ "worker.md" }, on_orchestrator.orchestrated)
    assert.is_nil(on_orchestrator.orchestrated_by)
    assert.same({ "orchestrator.md" }, on_worker.orchestrated_by)
    assert.is_nil(on_worker.orchestrated)
  end)

  it("encodes an explicit task into the orchestrator's `orchestrated` entry only (#696 follow-up)", function()
    local from, to = open_chat("orchestrator.md"), open_chat("worker.md")

    assert.is_true(OrchestrationLink.link(from, to, "PR #688 -- review fixes, merge"))

    assert.same({ "worker.md|PR #688 -- review fixes, merge" }, frontmatter_on_disk(dir .. "/orchestrator.md").orchestrated)
    -- The worker's own file never carries a `task` -- see orchestrated_entry.lua for why.
    assert.same({ "orchestrator.md" }, frontmatter_on_disk(dir .. "/worker.md").orchestrated_by)
  end)

  it("drops a task containing a line break rather than corrupting the encoded entry (PR #712 review)", function()
    local from, to = open_chat("orchestrator.md"), open_chat("worker.md")

    assert.is_true(OrchestrationLink.link(from, to, "line one\nline two"))

    assert.same({ "worker.md" }, frontmatter_on_disk(dir .. "/orchestrator.md").orchestrated)
  end)

  it(
    "repairs a missing backward link and updates the task in place, without duplicating the forward entry (PR #712 review)",
    function()
      local from, to = open_chat("orchestrator.md"), open_chat("worker.md")
      -- Simulate an earlier partial write: forward succeeded, backward never did (e.g. the
      -- worker side failed to save). `existing_entry` must still be found and updated in place
      -- rather than falling through to the "not yet linked" path, which would `add` a second,
      -- differently-encoded entry for the same worker path.
      FrontmatterHandler.update_list(from, "orchestrated", "worker.md|first task", "add")

      assert.is_true(OrchestrationLink.link(from, to, "second task"))

      assert.same({ "worker.md|second task" }, frontmatter_on_disk(dir .. "/orchestrator.md").orchestrated)
      assert.same({ "orchestrator.md" }, frontmatter_on_disk(dir .. "/worker.md").orchestrated_by)
    end
  )

  it("replaces the task on an existing link when a different one is given (latest instruction wins)", function()
    local from, to = open_chat("orchestrator.md"), open_chat("worker.md")
    assert.is_true(OrchestrationLink.link(from, to, "first task"))

    assert.is_true(OrchestrationLink.link(from, to, "second task"))

    assert.same({ "worker.md|second task" }, frontmatter_on_disk(dir .. "/orchestrator.md").orchestrated)
  end)

  it("keeps the existing task when a later link call omits it", function()
    -- `nvim_chat_send_message` calls without `task` for an ordinary follow-up must not blank out
    -- a good one-line assignment.
    local from, to = open_chat("orchestrator.md"), open_chat("worker.md")
    assert.is_true(OrchestrationLink.link(from, to, "keep me"))

    assert.is_true(OrchestrationLink.link(from, to))

    assert.same({ "worker.md|keep me" }, frontmatter_on_disk(dir .. "/orchestrator.md").orchestrated)
  end)

  it("treats a one-sided reverse record as enough to call it a report", function()
    -- `link` は片側だけ書けた状態を許して続行する（保存できた側でリネーム同期は動く）ので、
    -- 両側が揃っていることを前提にすると、その状態のチャットで逆向きが書かれてしまう
    local orchestrator, worker = open_chat("orchestrator.md"), open_chat("worker.md")
    refuse_writes_for = worker
    OrchestrationLink.link(orchestrator, worker)
    refuse_writes_for = nil

    assert.same({ "worker.md" }, frontmatter_on_disk(dir .. "/orchestrator.md").orchestrated)
    assert.is_nil(frontmatter_on_disk(dir .. "/worker.md").orchestrated_by)

    assert.is_true(OrchestrationLink.link(worker, orchestrator))

    assert.is_nil(frontmatter_on_disk(dir .. "/worker.md").orchestrated)
    assert.is_nil(frontmatter_on_disk(dir .. "/orchestrator.md").orchestrated_by)
  end)
end)
