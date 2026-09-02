---@diagnostic disable: undefined-field
--- What the handler writes into the .res file is the whole permission contract with the CLI, and
--- it is three-valued rather than two: an allowed call is either granted outright or handed back
--- to the CLI's own gate. Before #564 every allowed call took the second path, which in headless
--- `-p` mode simply refuses vibing-nvim's own MCP tools.
local permission = require("vibing.infrastructure.rpc.handlers.permission")

local HANDLE_ID = "decision-spec-handle"

local comm_dir

---`active_opts.cwd` に渡す、gitの外のディレクトリ
---
---許可された決定はどれも `_capture_baselines` を通り、そこで本当にベースラインを取る。
---`cwd` を渡さないと `git_snapshot` は Neovim のカレントディレクトリ — つまり開発中の
---リポジトリそのもの — を対象にしてしまい、テストを走らせるだけで実リポジトリに
---`refs/worktree/vibing/decision-spec-handle` とスナップショットのオブジェクトが残る。
---#664 で `git add` が通るようになって初めて表面化した（それまでは `git add` が exit 1 で
---落ちていたので、何も起きていなかった）。
---gitの外を指しておけば `worktree_root` が nil を返し、スナップショットは試みられない。
local sandbox_cwd

local function write_request(request_id, tool_name, tool_input)
  local f = assert(io.open(comm_dir .. "/" .. request_id .. ".req", "w"))
  f:write(vim.json.encode({ tool_name = tool_name, tool_input = tool_input or {} }))
  f:close()
end

--- @return table hookSpecificOutput
local function decide(request_id, tool_name, tool_input)
  write_request(request_id, tool_name, tool_input)
  permission.check_tool_permission({ request_id = request_id, handle_id = HANDLE_ID })

  local f = assert(io.open(comm_dir .. "/" .. request_id .. ".res", "r"))
  local content = f:read("*a")
  f:close()
  return vim.json.decode(content).hookSpecificOutput
end

describe("permission handler hook decision", function()
  local original_comm_dir

  before_each(function()
    original_comm_dir = vim.env.VIBING_HOOK_COMM_DIR
    comm_dir = vim.fn.tempname()
    vim.fn.mkdir(comm_dir, "p")
    vim.env.VIBING_HOOK_COMM_DIR = comm_dir
    sandbox_cwd = vim.fn.tempname()
    vim.fn.mkdir(sandbox_cwd, "p")
    permission.set_active_opts(HANDLE_ID, {
      permissions_allow = { "Read" },
      permissions_deny = { "Bash" },
      permission_mode = "acceptEdits",
      cwd = sandbox_cwd,
    })
  end)

  after_each(function()
    permission.clear_active_opts(HANDLE_ID)
    -- sandbox_cwd がgitの外である限りセッションは作られないが、ここは「作られていたら
    -- 実リポジトリのrefを残さずに片付ける」ための保険。clearは冪等。
    -- 下の `_capture_baselines` describe は git_snapshot を丸ごと差し替えるので、その復元より
    -- こちらが先に走ると `clear` が存在しない。保険をspecの失敗にはしない
    local GitSnapshot = require("vibing.core.utils.git_snapshot")
    if GitSnapshot.clear then
      GitSnapshot.clear(HANDLE_ID)
    end
    vim.env.VIBING_HOOK_COMM_DIR = original_comm_dir
    vim.fn.delete(comm_dir, "rf")
    vim.fn.delete(sandbox_cwd, "rf")
  end)

  it("takes no working-tree snapshot of the repository the suite runs in", function()
    -- 決定パスを通しても、このspecがスナップショットを取らないことを固定する。`cwd` を
    -- 実リポジトリに向け直すと、ここが落ちる
    decide("req-no-snapshot", "Edit", { file_path = sandbox_cwd .. "/x.txt" })

    assert.is_false(require("vibing.core.utils.git_snapshot").has_baseline(HANDLE_ID))
  end)

  it("grants vibing-nvim's own MCP tools outright", function()
    local output = decide("req-mcp", "mcp__plugin_vibing-nvim_vibing-nvim__nvim_list_windows", {})

    assert.equals("allow", output.permissionDecision)
    -- Without hookEventName the CLI does not read the object as a PreToolUse decision at all.
    assert.equals("PreToolUse", output.hookEventName)
  end)

  it("grants them whatever marketplace the plugin was installed from", function()
    -- The prefix is decided at install time and cannot be known here, which is exactly why the
    -- grant has to come from this suffix match rather than from --allowedTools.
    local output = decide("req-mcp-alt", "mcp__plugin_some-other-name_vibing-nvim__nvim_get_buffer", {})

    assert.equals("allow", output.permissionDecision)
  end)

  it("defers a server whose name merely ends with vibing-nvim", function()
    -- Permitted by the allow list, so the only question left is which of the two "yes" answers it
    -- gets. "allow" would hand an unrelated MCP server the same bypass of the user's own
    -- settings.json that vibing-nvim's own tools get.
    local LOOKALIKE = "mcp__my-vibing-nvim__nvim_get_buffer"
    permission.set_active_opts(HANDLE_ID, {
      permissions_allow = { LOOKALIKE },
      permission_mode = "acceptEdits",
    })

    local output = decide("req-lookalike", LOOKALIKE, {})

    assert.equals("defer", output.permissionDecision)
  end)

  it("defers an ordinary allowed tool to the CLI's own gate", function()
    -- Not "allow": granting every permitted tool would also override the deny rules in the user's
    -- own settings.json, which --setting-sources still pulls in.
    local output = decide("req-read", "Read", { file_path = "/tmp/x.lua" })

    assert.equals("defer", output.permissionDecision)
  end)

  it("denies with the reason attached", function()
    local output = decide("req-bash", "Bash", { command = "echo hi" })

    assert.equals("deny", output.permissionDecision)
    assert.is_truthy(output.permissionDecisionReason)
  end)
  describe("_capture_baselines", function()
    -- 2つのdiff機構のベースラインは独立していなければいけない。1つのpcallにまとめると、
    -- フォールバック(request_diff)の例外が主経路(git snapshot)を道連れにする。
    -- `Fs.ensure_dir` は競合以外の失敗を再raiseする契約なので、capture が投げる経路は実在する。
    local originals = {}
    -- 「元々ロードされていなかった」を表す番兵。`originals[name] = nil` はキーを作らないので、
    -- そのまま入れるとpairsが飛ばし、投げるスタブがpackage.loadedに残り続ける。ここでスタブ
    -- するモジュールは `_capture_baselines` の中で遅延requireされる＝このspecが先に走ると
    -- 未ロードなので、実際に起こりうる
    local ABSENT = {}

    local function stub(name, module)
      originals[name] = package.loaded[name] or ABSENT
      package.loaded[name] = module
    end

    after_each(function()
      for name, saved in pairs(originals) do
        package.loaded[name] = saved ~= ABSENT and saved or nil
      end
      originals = {}
    end)

    it("still takes the snapshot baseline when the fallback capture throws", function()
      local called = {}
      stub("vibing.core.utils.request_diff", {
        capture = function()
          error("read-only file system")
        end,
      })
      stub("vibing.core.utils.git_snapshot", {
        ensure_baseline = function()
          called.snapshot = true
        end,
      })

      permission._capture_baselines("h1", "/repo", "Bash", {})

      assert.is_true(called.snapshot)
    end)

    it("still takes the fallback capture when the snapshot baseline throws", function()
      local called = {}
      stub("vibing.core.utils.git_snapshot", {
        ensure_baseline = function()
          error("git exploded")
        end,
      })
      stub("vibing.core.utils.request_diff", {
        capture = function()
          called.capture = true
        end,
      })

      permission._capture_baselines("h2", "/repo", "Bash", {})

      assert.is_true(called.capture)
    end)

    it("never lets either failure escape to the permission decision", function()
      stub("vibing.core.utils.git_snapshot", {
        ensure_baseline = function()
          error("boom")
        end,
      })
      stub("vibing.core.utils.request_diff", {
        capture = function()
          error("boom")
        end,
      })

      assert.has_no.errors(function()
        permission._capture_baselines("h3", "/repo", "Bash", {})
      end)
    end)
  end)

end)
