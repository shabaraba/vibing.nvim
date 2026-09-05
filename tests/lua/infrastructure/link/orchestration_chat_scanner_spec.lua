local OrchestrationChatScanner = require("vibing.infrastructure.link.orchestration_chat_scanner")
local Frontmatter = require("vibing.infrastructure.storage.frontmatter")
local ChatFiles = require("tests.helpers.chat_files")
local Git = require("vibing.core.utils.git")

describe("OrchestrationChatScanner", function()
  local dir
  local original_get_root

  before_each(function()
    dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    original_get_root = Git.get_root
    -- 実際のリポジトリではなく一時ディレクトリをgitルートに見せる。こうすると
    -- `to_display_path` がそこからの相対パスを書き、スキャナーが同じルートで解決するので、
    -- git相対の経路をそのまま踏める
    Git.get_root = function()
      return dir
    end
  end)

  after_each(function()
    Git.get_root = original_get_root
    vim.fn.delete(dir, "rf")
  end)

  describe("contains_link", function()
    it("finds a chat that names the renamed file in orchestrated", function()
      local worker = dir .. "/worker.md"
      local orchestrator = ChatFiles.write(dir, "orchestrator.md", { orchestrated = { "worker.md" } })

      assert.is_true(OrchestrationChatScanner.new():contains_link(orchestrator, worker))
    end)

    it("finds a chat that names the renamed file in orchestrated_by", function()
      local orchestrator = dir .. "/orchestrator.md"
      local worker = ChatFiles.write(dir, "worker.md", { orchestrated_by = { "orchestrator.md" } })

      assert.is_true(OrchestrationChatScanner.new():contains_link(worker, orchestrator))
    end)

    it("normalizes a ~-shortened path the same way it normalizes a git-relative one", function()
      -- gitルートの外にあるチャット（`save_location_type = "user"` 等）は `to_display_path` が
      -- `~/...` の形で書く。$HOME を差し替えても `expand()` には効かない（Vimは起動時に
      -- ホームディレクトリを確定する）ので、実ホーム配下に置いて経路をそのまま踏む
      Git.get_root = function()
        return nil
      end

      local home_dir = vim.fn.expand("~") .. "/.vibing-orchestration-spec-" .. vim.fn.getpid()
      vim.fn.mkdir(home_dir, "p")
      local worker = home_dir .. "/worker.md"
      local orchestrator = ChatFiles.write(home_dir, "orchestrator.md", {
        orchestrated = { vim.fn.fnamemodify(worker, ":~") },
      })

      local found = OrchestrationChatScanner.new():contains_link(orchestrator, worker)
      vim.fn.delete(home_dir, "rf")

      assert.is_true(found)
    end)

    it("finds a task-bearing orchestrated entry by its path portion (#696 follow-up)", function()
      local worker = dir .. "/worker.md"
      local orchestrator = ChatFiles.write(dir, "orchestrator.md", {
        orchestrated = { "worker.md|PR #688 -- review fixes, merge" },
      })

      assert.is_true(OrchestrationChatScanner.new():contains_link(orchestrator, worker))
    end)

    it("reads a hand-written scalar link instead of erroring on it", function()
      -- `orchestrated: worker.md` と1行で書かれると table ではなく文字列でパースされる
      local worker = dir .. "/worker.md"
      local orchestrator = ChatFiles.write(dir, "orchestrator.md", { orchestrated = "worker.md" })

      assert.is_true(OrchestrationChatScanner.new():contains_link(orchestrator, worker))
    end)

    it("ignores a chat with no orchestration links", function()
      local other = ChatFiles.write(dir, "other.md", { forked_from = "worker.md" })

      assert.is_false(OrchestrationChatScanner.new():contains_link(other, dir .. "/worker.md"))
    end)

    it("ignores an empty link list rather than treating it as a match", function()
      -- 空リストは真値の table としてパースされるので、存在チェックだけでは弾けない
      local orchestrator = ChatFiles.write(dir, "orchestrator.md", { orchestrated = {} })

      assert.is_false(OrchestrationChatScanner.new():contains_link(orchestrator, dir .. "/worker.md"))
    end)

    it("ignores a markdown file that is not a vibing chat", function()
      local note = dir .. "/note.md"
      vim.fn.writefile({ "---", "orchestrated:", "  - worker.md", "---", "just a note" }, note)

      assert.is_false(OrchestrationChatScanner.new():contains_link(note, dir .. "/worker.md"))
    end)
  end)

  describe("update_link", function()
    it("replaces only the matching element and keeps the rest of the list", function()
      -- `ForkedChatScanner` をそのままコピーすると落ちる箇所。`forked_from` はスカラーなので
      -- キーごと差し替えられるが、リストで同じことをすると他の要素が消える
      local orchestrator = ChatFiles.write(dir, "orchestrator.md", {
        orchestrated = { "alpha.md", "worker.md", "bravo.md" },
      })

      local ok = OrchestrationChatScanner.new():update_link(orchestrator, dir .. "/worker.md", dir .. "/renamed.md")

      assert.is_true(ok)
      assert.same({ "alpha.md", "renamed.md", "bravo.md" }, ChatFiles.read_frontmatter(orchestrator).orchestrated)
    end)

    it("keeps the task suffix when renaming a task-bearing orchestrated entry (#696 follow-up)", function()
      local orchestrator = ChatFiles.write(dir, "orchestrator.md", {
        orchestrated = { "worker.md|PR #688 -- review fixes, merge" },
      })

      local ok = OrchestrationChatScanner.new():update_link(orchestrator, dir .. "/worker.md", dir .. "/renamed.md")

      assert.is_true(ok)
      assert.same(
        { "renamed.md|PR #688 -- review fixes, merge" },
        ChatFiles.read_frontmatter(orchestrator).orchestrated
      )
    end)

    it(
      "collapses a rename collision to one entry instead of keeping conflicting tasks for the same path (PR #712 review)",
      function()
        -- Renaming "worker.md" to "renamed.md" while "renamed.md" is already a separate
        -- orchestrated entry (with its own, different task) must not leave both encoded strings
        -- in the list -- nvim_chat_list would then have two conflicting assignments to project
        -- onto the same worker path.
        local orchestrator = ChatFiles.write(dir, "orchestrator.md", {
          orchestrated = { "worker.md|old task", "renamed.md|other task" },
        })

        local ok = OrchestrationChatScanner.new():update_link(orchestrator, dir .. "/worker.md", dir .. "/renamed.md")

        assert.is_true(ok)
        assert.equals(1, #ChatFiles.read_frontmatter(orchestrator).orchestrated)
      end
    )

    it("updates orchestrated_by as well as orchestrated", function()
      local worker = ChatFiles.write(dir, "worker.md", { orchestrated_by = { "orchestrator.md" } })

      local ok =
        OrchestrationChatScanner.new():update_link(worker, dir .. "/orchestrator.md", dir .. "/renamed.md")

      assert.is_true(ok)
      assert.same({ "renamed.md" }, ChatFiles.read_frontmatter(worker).orchestrated_by)
    end)

    it("does not leave a duplicate when the new name is already in the list", function()
      local orchestrator = ChatFiles.write(dir, "orchestrator.md", {
        orchestrated = { "worker.md", "renamed.md" },
      })

      local ok = OrchestrationChatScanner.new():update_link(orchestrator, dir .. "/worker.md", dir .. "/renamed.md")

      assert.is_true(ok)
      assert.same({ "renamed.md" }, ChatFiles.read_frontmatter(orchestrator).orchestrated)
    end)

    it("leaves other frontmatter keys untouched", function()
      local orchestrator = ChatFiles.write(dir, "orchestrator.md", {
        orchestrated = { "worker.md" },
        permissions_allow = { "Read", "Edit" },
        model = "sonnet",
      })

      OrchestrationChatScanner.new():update_link(orchestrator, dir .. "/worker.md", dir .. "/renamed.md")

      local frontmatter = ChatFiles.read_frontmatter(orchestrator)
      assert.same({ "Read", "Edit" }, frontmatter.permissions_allow)
      assert.equals("sonnet", frontmatter.model)
      assert.is_true(frontmatter["vibing.nvim"])
    end)

    it("writes through a loaded buffer instead of behind its back", function()
      -- オーケストレーションのリンクはbufnr起点で張られるので、同期の相手は常に開いている。
      -- ディスクを直接書くと、そのバッファの次の保存が同期内容を巻き戻すか、
      -- 「読み込み後にファイルが変わった」プロンプトでNeovimを止める
      local orchestrator = ChatFiles.write(dir, "orchestrator.md", { orchestrated = { "worker.md" } })
      local bufnr = vim.fn.bufadd(orchestrator)
      vim.fn.bufload(bufnr)

      local ok = OrchestrationChatScanner.new():update_link(orchestrator, dir .. "/worker.md", dir .. "/renamed.md")

      local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      local modified = vim.bo[bufnr].modified
      vim.api.nvim_buf_delete(bufnr, { force = true })

      assert.is_true(ok)
      assert.is_truthy(table.concat(lines, "\n"):find("renamed.md", 1, true), "buffer should carry the new link")
      assert.is_false(modified, "the buffer should be saved, not left dirty")
      -- ディスク側も追随している
      assert.same({ "renamed.md" }, ChatFiles.read_frontmatter(orchestrator).orchestrated)
    end)

    it("leaves the body of a loaded buffer alone", function()
      -- ストリーミング中のチャットを丸ごと書き換えると応答が壊れる。触るのはfrontmatterだけ
      local orchestrator = dir .. "/orchestrator.md"
      local body = "## User\n\nhello\n\n## Assistant\n\npartial reply"
      vim.fn.writefile(
        vim.split(
          Frontmatter.serialize({ ["vibing.nvim"] = true, orchestrated = { "worker.md" } }, body),
          "\n",
          { plain = true }
        ),
        orchestrator
      )
      local bufnr = vim.fn.bufadd(orchestrator)
      vim.fn.bufload(bufnr)

      OrchestrationChatScanner.new():update_link(orchestrator, dir .. "/worker.md", dir .. "/renamed.md")

      local text = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
      vim.api.nvim_buf_delete(bufnr, { force = true })

      assert.is_truthy(text:find("partial reply", 1, true), "the body must survive")
      assert.is_truthy(text:find("renamed.md", 1, true))
    end)

    it("reports a failure when the file has no matching link", function()
      local other = ChatFiles.write(dir, "other.md", { orchestrated = { "alpha.md" } })

      local ok, err = OrchestrationChatScanner.new():update_link(other, dir .. "/worker.md", dir .. "/renamed.md")

      assert.is_false(ok)
      assert.is_string(err)
    end)
  end)

  describe("find_target_files", function()
    it("returns nothing for a directory that does not exist", function()
      assert.same({}, OrchestrationChatScanner.new():find_target_files(dir .. "/missing/"))
    end)

    it("finds both .md and .vibing chat files", function()
      ChatFiles.write(dir, "a.md", {})
      ChatFiles.write(dir, "b.vibing", {})

      local files = OrchestrationChatScanner.new():find_target_files(dir .. "/")

      assert.equals(2, #files)
    end)
  end)
end)
