local PrivateFile = require("vibing.infrastructure.rpc.private_file")

local uv = vim.loop

describe("vibing.infrastructure.rpc.private_file", function()
  local root

  before_each(function()
    root = vim.fn.tempname()
    assert.is_true(PrivateFile.ensure_dir(root))
  end)

  after_each(function()
    vim.fn.delete(root, "rf")
  end)

  it("replaces a symlink at the path instead of writing through it", function()
    local victim = root .. "/victim"
    local fd = assert(uv.fs_open(victim, "w", tonumber("0644", 8)))
    uv.fs_write(fd, "original", 0)
    uv.fs_close(fd)
    local path = root .. "/token"
    assert.is_true(uv.fs_symlink(victim, path))

    assert.is_true(PrivateFile.write(path, "secret"))

    assert.same({ "original" }, vim.fn.readfile(victim))
    local st = assert(uv.fs_lstat(path))
    assert.equals("file", st.type)
    assert.equals(PrivateFile.FILE_MODE, st.mode % 4096)
    assert.same({ "secret" }, vim.fn.readfile(path))
  end)

  it("refuses a directory path that is a symlink", function()
    local link = root .. "/link"
    assert.is_true(uv.fs_symlink(root, link))

    local ok, why = PrivateFile.ensure_dir(link)

    assert.is_false(ok)
    assert.equals("symlink", why)
  end)
end)
