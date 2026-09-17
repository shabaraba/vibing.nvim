local Identity = require("vibing.core.utils.identity")

--- The repository root, reached from this spec's own path rather than from the cwd: `test:lua` runs
--- from the root today, but a spec that silently passes when the file it is checking cannot be found
--- is the failure mode these assertions exist to remove.
local function repo_root()
  local this = debug.getinfo(1, "S").source:sub(2)
  -- Anchored on a marker file rather than by counting `:h`s: a spec that moves one directory would
  -- otherwise point at the wrong root and lose the very gate below.
  return vim.fs.root(this, "package.json")
end

local function read(relative)
  local path = repo_root() .. "/" .. relative
  local f = assert(io.open(path, "r"), "could not open " .. path)
  local content = f:read("*a")
  f:close()
  return content
end

describe("core.utils.identity", function()
  local minters = {
    { name = "new_process_id", fn = Identity.new_process_id },
    { name = "new_turn_id", fn = Identity.new_turn_id },
  }

  for _, minter in ipairs(minters) do
    describe(minter.name, function()
      it("survives the shell hooks' sanitization unchanged", function()
        -- The constraint that actually matters, asserted directly instead of through a format
        -- pattern standing in for it: a dropped character makes the hook name an id that is not in
        -- the registry, and the turn then resolves to nil.
        for _ = 1, 20 do
          local id = minter.fn()
          assert.equals(id, (id:gsub(Identity.HOOK_SAFE_CLASS, "")), "not hook-safe: " .. id)
        end
      end)

      it("survives git_snapshot's ref-name sanitization unchanged", function()
        -- The turn id names `refs/worktree/vibing/<id>`; git_snapshot.sanitize drops anything
        -- outside `[%w%-_]` and documents that it is therefore the identity map on a real id.
        for _ = 1, 20 do
          local id = minter.fn()
          assert.equals(id, (id:gsub("[^%w%-_]", "")), "not ref-safe: " .. id)
        end
      end)

      it("is hex, never scientific notation", function()
        -- LuaJIT renders large hrtime doubles as "2.64e+15", whose `.` and `+` are both dropped by
        -- the class above -- so two ids minted in one millisecond could collapse onto one value.
        for _ = 1, 20 do
          local id = minter.fn()
          assert.is_truthy(id:match("^%x+_%x+$"), "not hex: " .. id)
          assert.is_nil(id:find("e+", 1, true))
        end
      end)

      it("does not repeat", function()
        local seen = {}
        for _ = 1, 200 do
          local id = minter.fn()
          assert.is_nil(seen[id], "duplicate id")
          seen[id] = true
        end
      end)
    end)
  end

  -- Nothing may parse an id to learn its kind, and the `^%x+_%x+$` assertion each minter is held to
  -- above is what makes the two indistinguishable. There is deliberately no test here asserting
  -- that in a third way: a shape comparison between two live ids is not stable, because the random
  -- suffix has a variable width.
  --
  -- Nor is there one asserting that the two minters return different values. It could not fail:
  -- both mint fresh, so it stays green even if one is aliased to the other — which is the mutation
  -- it would exist to catch. What the split actually promises is asserted where it is observable,
  -- in `stream_options_spec.lua`: the turn id `stream()` returns is not the `VIBING_PROCESS_ID` the
  -- child was handed.

  describe("the contract with bin/hooks", function()
    -- This gate did not exist before: cli_runtime.lua only *described* the shell's behaviour in a
    -- comment, so a rename on either side would have broken hook attribution with every unit test
    -- still green -- `test:lua` never runs the shell. The pairing is what is asserted, not either
    -- side alone.
    --
    -- These patterns are deliberately exact rather than lenient. Dropping the quotes, or writing a
    -- behaviourally identical class like `[^[:alnum:]_]`, fails here with "no sanitization found" —
    -- which is the safe direction, and the one to fix by updating both sides rather than by
    -- loosening the pattern.

    --- Globbed rather than listed: a third hook script must be covered by existing, not by someone
    --- remembering to add it here.
    local scripts = vim.fn.glob(repo_root() .. "/bin/hooks/*.sh", false, true)

    it("finds the hook scripts at all", function()
      -- Without this the loop below would be empty and the whole gate would pass by running nothing.
      assert.is_true(#scripts >= 2, "expected bin/hooks/*.sh, found " .. #scripts)
    end)

    for _, path in ipairs(scripts) do
      local script = vim.fn.fnamemodify(path, ":t")

      it(script .. " deletes exactly the character class identity.lua promises", function()
        local body = read("bin/hooks/" .. script)
        local class = body:match('PROCESS_ID="%${VIBING_PROCESS_ID//(%b[])/}"')
        assert.is_truthy(class, "no VIBING_PROCESS_ID sanitization found in " .. script)
        assert.equals(Identity.HOOK_SAFE_CLASS, class)
      end)

      it(script .. " sends the sanitized id under the key the RPC handlers read", function()
        -- `process_id`, not `turn_id`: an environment variable is fixed at spawn, so it can only
        -- ever name a process. A stale key here would resolve every hook to nil.
        --
        -- The whole printf is matched, argument order included. Asserting only that the key appears
        -- somewhere would stay green if the two `%s` arguments were swapped — which sends the
        -- request id as the process id and breaks every attribution while looking untouched.
        local body = read("bin/hooks/" .. script)
        local args = body:match('"request_id":"%%s","process_id":"%%s"}}\\n\'%s+("[^\n]+)')
        assert.is_truthy(args, "no request_id/process_id printf found in " .. script)
        assert.equals('"$REQUEST_ID" "$PROCESS_ID"', vim.trim(args:gsub("\\$", "")))
        assert.is_nil(body:find("VIBING_HANDLE_ID", 1, true), "still reads the pre-#774 variable")
      end)
    end
  end)
end)
