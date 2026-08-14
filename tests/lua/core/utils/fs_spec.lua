local Fs = require("vibing.core.utils.fs")

describe("fs.ensure_dir", function()
  local tmp, original_mkdir

  before_each(function()
    tmp = vim.fn.tempname()
    original_mkdir = vim.fn.mkdir
  end)

  after_each(function()
    vim.fn.mkdir = original_mkdir
    vim.fn.delete(tmp, "rf")
  end)

  local function is_dir(path)
    local stat = vim.loop.fs_stat(path)
    return stat ~= nil and stat.type == "directory"
  end

  it("creates the directory", function()
    assert.is_true(Fs.ensure_dir(tmp))
    assert.is_true(is_dir(tmp))
  end)

  it("creates intermediate components", function()
    local nested = tmp .. "/a/b/c"
    assert.is_true(Fs.ensure_dir(nested))
    assert.is_true(is_dir(nested))
  end)

  it("succeeds on a directory that already exists", function()
    assert.is_true(Fs.ensure_dir(tmp))
    assert.is_true(Fs.ensure_dir(tmp))
  end)

  it("succeeds when another process won the race", function()
    -- The real failure, verbatim: mkdir(..., "p") walks the path and raises when a concurrent
    -- process creates a component first. 9 occurrences across 200 concurrent calls (#576).
    original_mkdir(tmp, "p")
    vim.fn.mkdir = function(path)
      error(string.format("Vim:E739: Cannot create directory %s: file already exists", path))
    end

    assert.is_true(Fs.ensure_dir(tmp), "losing the race must not be reported as failure")
  end)

  it("retries when the collision was on an intermediate component", function()
    -- The case a plain catch-and-recheck gets wrong, and the reason this helper retries. The
    -- process that won an intermediate component has not necessarily reached the leaf yet, so
    -- the loser's fs_stat on the leaf legitimately finds nothing. Re-checking returns false;
    -- re-attempting succeeds. Measured: catch-and-recheck still failed 3 times in 200.
    local leaf = tmp .. "/parent/leaf"
    local attempts = 0
    vim.fn.mkdir = function(path, flags)
      attempts = attempts + 1
      if attempts == 1 then
        -- Someone else just created `parent`; the leaf does not exist yet.
        original_mkdir(tmp .. "/parent", "p")
        error(string.format("Vim:E739: Cannot create directory %s/parent: file already exists", tmp))
      end
      return original_mkdir(path, flags)
    end

    assert.is_true(Fs.ensure_dir(leaf))
    assert.equals(2, attempts, "should have re-attempted, not just re-checked")
    assert.is_true(is_dir(leaf))
  end)

  it("gives up rather than spinning when the path can never be created", function()
    local attempts = 0
    vim.fn.mkdir = function()
      attempts = attempts + 1
      error("Vim:E739: Cannot create directory /nope: file already exists")
    end

    assert.is_false(pcall(Fs.ensure_dir, tmp .. "/never-created"))
    assert.is_true(attempts <= 5, "retries must be bounded, got " .. attempts)
  end)

  it("raises when mkdir declines without raising", function()
    vim.fn.mkdir = function()
      return 0
    end

    assert.is_false(pcall(Fs.ensure_dir, tmp .. "/never-created"))
  end)

  it("reports failure when the path exists but is a file", function()
    -- E739 says "file already exists" for this too, and the caller wants a directory.
    original_mkdir(tmp, "p")
    local file = tmp .. "/afile"
    vim.fn.writefile({}, file)

    assert.is_false(pcall(Fs.ensure_dir, file))
  end)
end)

describe("mkdir call sites", function()
  it("all go through fs.ensure_dir", function()
    -- `vim.fn.mkdir` is not atomic, so a direct call anywhere in lua/ is a latent flake. Keeping
    -- this as a test rather than a comment is what stops the next one being added silently.
    local root = vim.fn.getcwd() .. "/lua"
    local hits = vim.fn.systemlist({ "grep", "-rn", "vim.fn.mkdir(", root })

    local offenders = {}
    for _, line in ipairs(hits) do
      -- fs.lua is the one place allowed to call it, in the implementation and its own comment.
      if not line:match("core/utils/fs%.lua") then
        table.insert(offenders, (line:gsub("^" .. vim.pesc(root), "lua")))
      end
    end

    -- Positive control: fs.lua itself calls it, so an empty result means the grep looked at the
    -- wrong tree rather than that the tree is clean.
    assert.is_true(#hits > 0, "grep found nothing at all -- did it run against the right lua/?")
    assert.equals(0, #offenders, "direct vim.fn.mkdir call(s):\n" .. table.concat(offenders, "\n"))
  end)
end)
