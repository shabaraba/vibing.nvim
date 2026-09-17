---@diagnostic disable: undefined-field
--- Two Neovims open on one repository, and the generated files under `<cwd>/.vibing/` they used to
--- share.
---
--- Sharing was free while the contents were identical for both. It stopped being free when the hook
--- settings started carrying a timeout derived from `permissions.approval_wait_sec`: the script's
--- own deadline reaches the CLI child in its environment and is fixed at spawn, while that timeout
--- lives in a file that is not. A second Neovim with a lower value rewriting it puts the CLI's
--- deadline *ahead* of the script's, which is the one ordering under which every CLI measured fails
--- open and runs the tool with no verdict at all.
---
--- The fix is to make the question not arise rather than to detect it, so what these assert is
--- isolation: one instance's file is not the other's, and a sweep that cleans up after dead
--- instances cannot reach a live one's.
local CopilotSettingsGenerator = require("vibing.infrastructure.hooks.copilot_settings_generator")
local InstanceKey = require("vibing.infrastructure.rpc.instance_key")
local SettingsGenerator = require("vibing.infrastructure.hooks.settings_generator")

describe("instance_key", function()
  local tmp_dir

  before_each(function()
    tmp_dir = vim.fn.tempname()
    vim.fn.mkdir(tmp_dir .. "/.vibing", "p")
    InstanceKey._forget_swept()
  end)

  after_each(function()
    vim.fn.delete(tmp_dir, "rf")
    InstanceKey._forget_swept()
  end)

  it("is the RPC port when there is one, so a CLI child's binding and its settings agree", function()
    local key = InstanceKey.get()
    local port = require("vibing.infrastructure.rpc.server").get_port()
    if port and port ~= 0 then
      assert.equals(tostring(port), key)
    else
      -- No port: still per-process, because two portless instances must not collide either.
      assert.equals("0-" .. vim.fn.getpid(), key)
    end
  end)

  it("matches its own key with the pattern the sweeps are built from", function()
    -- The sweeps recognise a leftover by matching this pattern against a filename. A key this
    -- pattern does not match is a file nothing ever cleans up; a pattern too loose deletes
    -- something else in `.vibing/`.
    assert.is_truthy(InstanceKey.get():match("^" .. InstanceKey.PATTERN .. "$"))
  end)

  it("counts this instance as live even with no registry to read", function()
    assert.is_true(InstanceKey.live()[InstanceKey.get()])
  end)

  describe("the generated files", function()
    it("gives the hook settings and the copilot plugin a name of their own", function()
      local settings = SettingsGenerator.ensure(tmp_dir)
      local plugin = CopilotSettingsGenerator.ensure(tmp_dir)

      local key = InstanceKey.get()
      assert.is_truthy(settings:find(key, 1, true), "settings path must carry the instance key: " .. settings)
      assert.is_truthy(plugin:find(key, 1, true), "plugin dir must carry the instance key: " .. plugin)
    end)

    it("does not write the shared names the project used to have", function()
      SettingsGenerator.ensure(tmp_dir)
      CopilotSettingsGenerator.ensure(tmp_dir)

      assert.equals(0, vim.fn.filereadable(tmp_dir .. "/.vibing/hook-settings.json"))
      assert.equals(0, vim.fn.isdirectory(vim.fn.resolve(tmp_dir) .. "/.vibing/copilot-plugin"))
    end)
  end)

  describe("the sweep", function()
    local function vibing_dir()
      return vim.fn.resolve(tmp_dir) .. "/.vibing"
    end

    it("removes what a dead instance left behind", function()
      local dead = vibing_dir() .. "/hook-settings-65535.json"
      vim.fn.writefile({ "{}" }, dead)

      SettingsGenerator.ensure(tmp_dir)

      assert.equals(0, vim.fn.filereadable(dead))
    end)

    it("leaves this instance's own file alone", function()
      -- The sweep runs from inside `ensure`, so getting this wrong deletes the file that call just
      -- wrote — and a CLI spawned with `--settings` pointing at nothing runs with no hook at all.
      local path = SettingsGenerator.ensure(tmp_dir)
      assert.equals(1, vim.fn.filereadable(path))

      InstanceKey._forget_swept()
      assert.equals(path, SettingsGenerator.ensure(tmp_dir))
      assert.equals(1, vim.fn.filereadable(path))
    end)

    it("leaves a live instance's file alone", function()
      -- Deleting a *running* Neovim's settings takes its permission gate with it on its next
      -- spawn, which fails open. The registry is what says who is running.
      local live_key = "65534"
      local other = vibing_dir() .. "/hook-settings-" .. live_key .. ".json"
      vim.fn.writefile({ "{}" }, other)

      local original = InstanceKey.live
      ---@diagnostic disable-next-line: duplicate-set-field
      InstanceKey.live = function()
        return { [InstanceKey.get()] = true, [live_key] = true }
      end
      local ok, err = pcall(function()
        SettingsGenerator.ensure(tmp_dir)
      end)
      InstanceKey.live = original
      assert.is_true(ok, tostring(err))

      assert.equals(1, vim.fn.filereadable(other))
    end)

    it("leaves everything else in .vibing/ alone", function()
      -- `.vibing/` holds chat files, patches, the limit state and the worktrees. A sweep that
      -- matched loosely would take one of those.
      local bystanders = {
        vibing_dir() .. "/limit-state.json",
        vibing_dir() .. "/hook-settings.json",
        vibing_dir() .. "/hook-settings-notakey.json",
      }
      for _, path in ipairs(bystanders) do
        vim.fn.writefile({ "{}" }, path)
      end

      SettingsGenerator.ensure(tmp_dir)

      for _, path in ipairs(bystanders) do
        assert.equals(1, vim.fn.filereadable(path), path .. " must not be swept")
      end
    end)

    it("removes a dead instance's copilot plugin directory, contents and all", function()
      local dead = vibing_dir() .. "/copilot-plugin-65535"
      vim.fn.mkdir(dead, "p")
      vim.fn.writefile({ "{}" }, dead .. "/plugin.json")

      CopilotSettingsGenerator.ensure(tmp_dir)

      assert.equals(0, vim.fn.isdirectory(dead))
    end)

    it("scans a directory once per session, since ensure runs on every spawn", function()
      -- A scandir per turn is synchronous I/O on the main loop, and the sweep buys nothing after
      -- the first pass.
      local dead = vibing_dir() .. "/hook-settings-65535.json"
      SettingsGenerator.ensure(tmp_dir)

      vim.fn.writefile({ "{}" }, dead)
      SettingsGenerator.ensure(tmp_dir)

      assert.equals(1, vim.fn.filereadable(dead))
    end)
  end)
end)
