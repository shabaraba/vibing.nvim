-- `working_dir` が空のままだと、worktreeの中で何を書き換えても `### Modified Files` は0件になる
-- （スナップショットの基準が親リポジトリのままで、`.vibing/worktrees/` はそこでは無視対象）。
-- スキルの手順に頼ると書かれないターンが出るので、ここで書く。固定したいのは2つ:
--   * worktreeが **実際に増えたときだけ** 書くこと。失敗したコマンドの後に書くと、存在しない
--     ディレクトリを指したチャットができあがる
--   * シェルを読まないこと。判定は `git worktree list` の前後比較なので、`-b` の有無や
--     引用符や変数展開に左右されない
local Git = require("vibing.core.utils.git")
local FrontmatterHandler = require("vibing.presentation.chat.modules.frontmatter_handler")
local ChatFiles = require("tests.helpers.chat_files")
local view = require("vibing.presentation.chat.view")

describe("WorktreeBinding", function()
  local WorktreeBinding
  local original_get_root, original_get_chat_buffer, original_notify
  local repo, bufnr
  local notices

  local function git(...)
    return vim.system({ "git", "-C", repo, ... }, { text = true }):wait()
  end

  ---@param frontmatter table?
  local function open_chat(frontmatter)
    ChatFiles.write(repo, "chat.md", frontmatter or {})
    bufnr = vim.fn.bufadd(repo .. "/chat.md")
    vim.fn.bufload(bufnr)
    return bufnr
  end

  local function working_dir()
    return FrontmatterHandler.parse(bufnr).working_dir
  end

  ---1ターンぶん: ツールを見せてから実際に走らせ、ターン終わりを呼ぶ
  local function turn(tool_name, tool_input, run)
    WorktreeBinding.observe("h1", repo, tool_name, tool_input)
    if run then
      run()
    end
    return WorktreeBinding.resolve("h1", bufnr)
  end

  before_each(function()
    original_get_root = Git.get_root
    original_get_chat_buffer = view.get_chat_buffer
    original_notify = vim.notify
    notices = {}

    repo = vim.fn.resolve(vim.fn.tempname())
    vim.fn.mkdir(repo, "p")
    git("init", "-q")
    git("config", "user.email", "t@example.com")
    git("config", "user.name", "t")
    vim.fn.writefile({ ".vibing/" }, repo .. "/.gitignore")
    git("add", "-A")
    git("commit", "-qm", "init")

    Git.get_root = function()
      return repo
    end
    view.get_chat_buffer = function(b)
      if not vim.api.nvim_buf_is_valid(b) then
        return nil
      end
      return {
        parse_frontmatter = function()
          return FrontmatterHandler.parse(b)
        end,
        update_frontmatter = function(_, key, value)
          return FrontmatterHandler.update_field(b, key, value)
        end,
      }
    end
    vim.notify = function(msg, level)
      table.insert(notices, { msg = msg, level = level })
    end

    package.loaded["vibing.application.chat.worktree_binding"] = nil
    WorktreeBinding = require("vibing.application.chat.worktree_binding")
  end)

  after_each(function()
    Git.get_root = original_get_root
    view.get_chat_buffer = original_get_chat_buffer
    vim.notify = original_notify
    if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
      vim.api.nvim_buf_delete(bufnr, { force = true })
    end
    vim.fn.delete(repo, "rf")
  end)

  it("binds the chat to the worktree a Bash command created", function()
    open_chat()

    local written = turn("Bash", { command = "git worktree add -b feat .vibing/worktrees/feat" }, function()
      git("worktree", "add", "-q", "-b", "feat", ".vibing/worktrees/feat")
    end)

    assert.equals(".vibing/worktrees/feat", written)
    assert.equals(".vibing/worktrees/feat", working_dir())
  end)

  it("writes nothing when the command created no worktree", function()
    open_chat()

    -- ブランチ名の衝突などで `git worktree add` は普通に失敗する。そこで書いてしまうと、
    -- 存在しないディレクトリを指したチャットができあがる
    local written = turn("Bash", { command = "git worktree add -b feat .vibing/worktrees/feat" }, nil)

    assert.is_nil(written)
    assert.is_nil(working_dir())
  end)

  it("refuses to guess when one turn created several worktrees", function()
    open_chat()

    local written = turn("Bash", { command = "git worktree add -b a .vibing/worktrees/a" }, function()
      git("worktree", "add", "-q", "-b", "a", ".vibing/worktrees/a")
      git("worktree", "add", "-q", "-b", "b", ".vibing/worktrees/b")
    end)

    assert.is_nil(written)
    assert.is_nil(working_dir())
    assert.equals(vim.log.levels.WARN, notices[1].level)
    assert.is_truthy(notices[1].msg:find("more than one worktree", 1, true))
  end)

  it("takes the path EnterWorktree named, without diffing the list", function()
    open_chat()
    git("worktree", "add", "-q", "-b", "feat", ".vibing/worktrees/feat")

    -- 既存のworktreeに入るので前後で一覧は変わらない。差分に頼ると何も見つからない
    local written = turn("EnterWorktree", { path = repo .. "/.vibing/worktrees/feat" }, nil)

    assert.equals(".vibing/worktrees/feat", written)
  end)

  it("leaves a Bash command that is not a worktree add alone", function()
    open_chat()

    local written = turn("Bash", { command = "git worktree list" }, function()
      git("worktree", "add", "-q", "-b", "feat", ".vibing/worktrees/feat")
    end)

    assert.is_nil(written)
    assert.is_nil(working_dir())
  end)

  it("clears working_dir when ExitWorktree leaves a worktree", function()
    git("worktree", "add", "-q", "-b", "feat", ".vibing/worktrees/feat")
    open_chat({ working_dir = ".vibing/worktrees/feat" })

    turn("ExitWorktree", { action = "keep" }, nil)

    assert.is_nil(working_dir())
  end)

  it("leaves a working_dir that is not a worktree alone on exit", function()
    vim.fn.mkdir(repo .. "/sub", "p")
    open_chat({ working_dir = "sub" })

    -- ユーザーが別の目的で設定した値を、worktreeを出たついでに消してはいけない
    turn("ExitWorktree", { action = "keep" }, nil)

    assert.equals("sub", working_dir())
  end)

  it("forgets the turn once it is resolved", function()
    open_chat()
    turn("Bash", { command = "git worktree add -b feat .vibing/worktrees/feat" }, function()
      git("worktree", "add", "-q", "-b", "feat", ".vibing/worktrees/feat")
    end)

    -- 次のターンが同じ予約を引き継ぐと、worktreeに触っていないターンでも書き込みが起きる
    FrontmatterHandler.update_field(bufnr, "working_dir", nil)
    assert.is_nil(WorktreeBinding.resolve("h1", bufnr))
    assert.is_nil(working_dir())
  end)

  it("classifies the tools it reacts to", function()
    local Scan = require("vibing.application.chat.worktree_scan")

    assert.equals("enter", (Scan.classify("EnterWorktree", { name = "x" })))
    assert.equals("exit", (Scan.classify("ExitWorktree", { action = "keep" })))
    assert.equals("create", (Scan.classify("Bash", { command = "git worktree add x" })))
    assert.is_nil((Scan.classify("Bash", { command = "git status" })))
    assert.is_nil((Scan.classify("Write", { file_path = "a.lua" })))
    assert.is_nil((Scan.classify("EnterWorktree", "not a table")))
  end)
end)
