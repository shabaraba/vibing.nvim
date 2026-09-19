-- Every `vim.fn.mkdir` in this repository, held to one rule.
--
-- `vim.fn.mkdir(path, "p")` is not atomic: it walks the path creating each component and raises
-- E739 when another process creates one in between (9 failures in 200 concurrent calls, #576).
-- `fs.ensure_dir` is the one call that survives that.
--
-- The rule is about **shared state**, not about which directory the file sits in:
--
--   * in `lua/`, nothing but `fs.lua` may call it -- production paths are shared by construction
--     (the machine-wide instance registry, a project's `.vibing/`, every chat open on it);
--   * in `tests/`, a call is allowed when its path is unique to this process, which here means
--     rooted at `vim.fn.tempname()`. Plenary runs one child Neovim per spec file, concurrently,
--     so a fixed path under the cwd or under `$HOME` is shared between them -- and it was a spec,
--     `tests/view_spec.lua`, that flaked in CI and produced `fs.ensure_dir` in the first place.
--
-- The guard used to scan `lua/` only, which is the boundary that lets the failure it was written
-- for back in.
--
-- **Anything the analysis cannot prove unique is reported.** A false positive is noticed and
-- fixed in a minute; a false negative is the silent pass this guard exists to stop. The two
-- remedies are a `tempname()` root and `Fs.ensure_dir`, and `-- mkdir-ok: <reason>`, on the call
-- or on the line above it, waives one that genuinely cannot have either.

local Analysis = require("tests.helpers.mkdir_analysis")

describe("the analysis behind the guard", function()
  -- The scans below are all of the form "no file does X", which an analysis that recognises
  -- nothing satisfies for free. These say what it recognises.
  local function unproven(source)
    return Analysis.unproven_calls(vim.split(source, "\n", { plain = true }))
  end

  it("accepts a path rooted at tempname(), however far back", function()
    assert.same({}, unproven('local base = vim.fn.tempname()\nvim.fn.mkdir(base, "p")'))
    assert.same({}, unproven('local base = vim.fn.tempname()\nvim.fn.mkdir(base .. "/a/b", "p")'))
    assert.same(
      {},
      unproven(
        'local base = vim.fn.tempname()\nlocal leaf = base .. "/x"\nvim.fn.mkdir(leaf, "p")'
      )
    )
    assert.same(
      {},
      unproven(
        'local p = vim.fn.tempname() .. "/f.txt"\nvim.fn.mkdir(vim.fn.fnamemodify(p, ":h"), "p")'
      )
    )
  end)

  it("reports a path that is not", function()
    assert.equals(1, #unproven('vim.fn.mkdir("/tmp/fixed", "p")'))
    assert.equals(1, #unproven('local d = vim.fn.getcwd() .. "/out"\nvim.fn.mkdir(d, "p")'))
    assert.equals(1, #unproven('local d = vim.fn.expand("~") .. "/out"\nvim.fn.mkdir(d, "p")'))
    -- Fail-closed: a parameter is not traced to its callers, so it is not proof.
    assert.equals(1, #unproven('local function w(dir)\n  vim.fn.mkdir(dir, "p")\nend'))
  end)

  it("reads the assignment above the call, not the first one in the file", function()
    -- A file with four `local test_dir = ...` is the normal shape here, one per `it` block.
    -- Clearing the name off the first tempname() sighting is how three fixed call sites hide a
    -- fourth that was left behind -- which is the whole failure, in miniature.
    local source = 'local test_dir = vim.fn.tempname() .. "/a"\n'
      .. 'vim.fn.mkdir(test_dir, "p")\n'
      .. 'local test_dir = vim.fn.getcwd() .. "/b"\n'
      .. 'vim.fn.mkdir(test_dir, "p")\n'
    local reported = unproven(source)
    assert.equals(1, #reported)
    assert.equals(4, reported[1].line)
  end)

  it("honours an explicit waiver on the line", function()
    assert.same({}, unproven('-- mkdir-ok: has to be $HOME\nvim.fn.mkdir(home, "p")'))
  end)
end)

describe("mkdir call sites", function()
  -- Rooted at this spec's own path, never at `vim.fn.getcwd()`: `test:lua` invokes Neovim with a
  -- relative `-u tests/minimal_init.lua`, so the cwd the command was typed in decides which
  -- checkout runs, and a cwd-rooted scan reports on whichever tree that was. No positive control
  -- catches it either -- every checkout of this repository satisfies "the scan found something".
  local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h")

  before_each(function()
    assert.equals(
      1,
      vim.fn.filereadable(root .. "/lua/vibing/core/utils/fs.lua"),
      "repo root resolved to " .. root .. " -- has this spec moved? the ':h' count follows it"
    )
  end)

  it("in lua/ all go through fs.ensure_dir", function()
    local hits = vim.fn.systemlist({ "grep", "-rn", Analysis.MKDIR, root .. "/lua" })

    local offenders = {}
    for _, line in ipairs(hits) do
      -- fs.lua is the one place allowed to call it, in the implementation and its own comment.
      if not line:match("core/utils/fs%.lua") then
        table.insert(offenders, (line:gsub("^" .. vim.pesc(root) .. "/", "")))
      end
    end

    -- Positive control: fs.lua itself calls it, so an empty result would mean the grep looked at
    -- the wrong tree rather than that the tree is clean.
    assert.is_true(#hits > 0, "the grep found nothing at all in lua/")
    assert.equals(0, #offenders, "direct vim.fn.mkdir call(s):\n" .. table.concat(offenders, "\n"))
  end)

  it("in tests/ all create a path unique to the process", function()
    -- By file, not by pattern. The two exempt files spell `vim.fn.mkdir(` out as text -- the
    -- constant the scan greps with, and the sources in the analysis tests above -- and excluding
    -- text that looks like that would take the next real offender written the same way with it.
    local exempt = {
      [vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p")] = true,
      [root .. "/tests/helpers/mkdir_analysis.lua"] = true,
    }
    local files = vim.fn.globpath(root .. "/tests", "**/*.lua", false, true)

    local offenders = {}
    local scanned = 0
    for _, file in ipairs(files) do
      if not exempt[vim.fn.fnamemodify(file, ":p")] then
        scanned = scanned + 1
        for _, call in ipairs(Analysis.unproven_calls(vim.fn.readfile(file))) do
          local shown = file:gsub("^" .. vim.pesc(root) .. "/", "")
          table.insert(offenders, ("%s:%d: %s"):format(shown, call.line, call.expr))
        end
      end
    end

    assert.is_true(scanned > 100, "only " .. scanned .. " spec files scanned")
    assert.equals(
      0,
      #offenders,
      "mkdir on a path that is not unique to this process; use vim.fn.tempname() or "
        .. "Fs.ensure_dir:\n"
        .. table.concat(offenders, "\n")
    )
  end)
end)
