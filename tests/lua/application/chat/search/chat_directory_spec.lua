local ChatDirectory = require("vibing.application.chat.search.chat_directory")

describe("chat search directory", function()
  local base

  local function real(path)
    return path and vim.fn.resolve(path) or nil
  end

  before_each(function()
    base = vim.fn.tempname() .. "_chat_directory"
    vim.fn.mkdir(base .. "/sub", "p")
  end)

  after_each(function()
    vim.fn.delete(base, "rf")
  end)

  local function git_init()
    vim.system({ "git", "init", "-q", base }):wait()
  end

  it("prefers the git root's .vibing/chat over the current directory", function()
    git_init()
    vim.fn.mkdir(base .. "/.vibing/chat", "p")
    vim.fn.mkdir(base .. "/sub/.vibing/chat", "p")

    assert.are.equal(real(base .. "/.vibing/chat"), real(ChatDirectory.resolve(base .. "/sub")))
  end)

  it("falls back to the current directory when the git root has none", function()
    git_init()
    vim.fn.mkdir(base .. "/sub/.vibing/chat", "p")

    assert.are.equal(real(base .. "/sub/.vibing/chat"), real(ChatDirectory.resolve(base .. "/sub")))
  end)

  it("uses the current directory outside a git repository", function()
    vim.fn.mkdir(base .. "/sub/.vibing/chat", "p")

    assert.are.equal(real(base .. "/sub/.vibing/chat"), real(ChatDirectory.resolve(base .. "/sub")))
  end)

  it("returns nil when neither exists", function()
    assert.is_nil(ChatDirectory.resolve(base .. "/sub"))
  end)
end)
