local Git = require("vibing.core.utils.git")

describe("OrchestrationLink.resolve_bufnrs", function()
  ---gitルートのキャッシュはモジュールレベルなのでspec間で持ち越す。毎回requireし直して捨てる
  local OrchestrationLink
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
    dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    buffers = {}

    package.loaded["vibing.application.chat.orchestration_link"] = nil
    OrchestrationLink = require("vibing.application.chat.orchestration_link")
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

    assert.same({ bufnr }, OrchestrationLink.resolve_bufnrs({ "worker.md" }))
  end)

  it("accepts the hand-written scalar form", function()
    Git.get_root = function()
      return dir
    end
    local bufnr = open_buffer("worker.md")

    assert.same({ bufnr }, OrchestrationLink.resolve_bufnrs("worker.md"))
  end)

  it("returns nothing for an absent or empty list", function()
    assert.same({}, OrchestrationLink.resolve_bufnrs(nil))
    assert.same({}, OrchestrationLink.resolve_bufnrs({}))
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

    assert.same({}, OrchestrationLink.resolve_bufnrs({ "worker.md" }))

    Git.get_root = function()
      calls = calls + 1
      return dir
    end

    assert.same({ bufnr }, OrchestrationLink.resolve_bufnrs({ "worker.md" }))
    assert.equals(2, calls, "a failed lookup must not be remembered")
  end)

  it("caches a successful lookup instead of spawning git per send", function()
    local calls = 0
    Git.get_root = function()
      calls = calls + 1
      return dir
    end
    open_buffer("worker.md")

    OrchestrationLink.resolve_bufnrs({ "worker.md" })
    OrchestrationLink.resolve_bufnrs({ "worker.md" })
    OrchestrationLink.resolve_bufnrs({ "worker.md" })

    assert.equals(1, calls)
  end)
end)
