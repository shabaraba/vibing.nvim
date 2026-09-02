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

---`active_opts` を差し替える唯一の入口
---
---`set_active_opts` は渡したテーブルで **丸ごと置き換える** ので、権限だけを差し替えたい
---テストが `cwd` を書き忘れると、そのテストだけが実リポジトリをスナップショットしてしまう。
---before_each で1度渡すだけでは足りず、実際に1件見落としていた（#665 のレビュー指摘）。
---入口を1つにしておけば、テストを足すときに `cwd` を意識する必要がなくなる。
---@param opts table
local function activate(opts)
  permission.set_active_opts(HANDLE_ID, vim.tbl_extend("force", { cwd = sandbox_cwd }, opts))
end

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
    activate({
      permissions_allow = { "Read" },
      permissions_deny = { "Bash" },
      permission_mode = "acceptEdits",
    })
  end)

  after_each(function()
    permission.clear_active_opts(HANDLE_ID)
    -- 「このspecはスナップショットを取らない」を全テストに効く不変条件として毎回見る。
    -- `activate` を入口に1つ用意しても、それを通さない `set_active_opts` を直に呼ぶテストが
    -- 足されれば `cwd` は落ちる（#665 のレビューで実在した見落とし）。ここで見ておけば、
    -- あとから足したテストも書き手が意識せずに守られる — `after_each` の失敗は
    -- PlenaryBustedDirectory の終了コードに乗るので、CIのゲートに届く（実測）。
    --
    -- clearを先に済ませてからassertするのは、落ちた場合でも実リポジトリにrefを残さないため。
    -- 下の `_capture_baselines` describe は git_snapshot を丸ごと差し替えるので、その復元より
    -- こちらが先に走ることがある。差し替え中は見ない
    local GitSnapshot = require("vibing.core.utils.git_snapshot")
    if GitSnapshot.has_baseline and GitSnapshot.clear then
      local snapshotted = GitSnapshot.has_baseline(HANDLE_ID)
      GitSnapshot.clear(HANDLE_ID)
      assert.is_false(snapshotted)
    end
    vim.env.VIBING_HOOK_COMM_DIR = original_comm_dir
    vim.fn.delete(comm_dir, "rf")
    vim.fn.delete(sandbox_cwd, "rf")
  end)

  it("takes no working-tree snapshot of the repository the suite runs in", function()
    -- 決定パスを通しても、このspecがスナップショットを取らないことを固定する。`cwd` を
    -- 実リポジトリに向け直すと、ここが落ちる
    local GitSnapshot = require("vibing.core.utils.git_snapshot")

    decide("req-no-snapshot", "Edit", { file_path = sandbox_cwd .. "/x.txt" })
    assert.is_false(GitSnapshot.has_baseline(HANDLE_ID))

    -- 権限を差し替えたあとも同じであること。`set_active_opts` を直に呼ぶと `cwd` が落ちるので、
    -- `activate` を経由しない再設定が入ったらここが落ちる
    activate({ permissions_allow = { "Edit" }, permission_mode = "acceptEdits" })
    decide("req-no-snapshot-2", "Edit", { file_path = sandbox_cwd .. "/y.txt" })
    assert.is_false(GitSnapshot.has_baseline(HANDLE_ID))
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
    activate({
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

  describe("session permissions belong to one chat", function()
    -- 承認UIで出した答えは、答えたチャットのセッションに属する。以前はこれが
    -- `permission.lua` のモジュールレベルのテーブルに入っていて、チャットでも handle_id でも
    -- キーされていなかったので、使い捨てワーカーで一度 `allow_for_session` を出すと
    -- エディタ上の全チャットに効き、各チャット自身の `permissions_ask` を迂回していた（#667）。
    --
    -- 2つのハンドルを同時に登録するのが要点。1つしか登録していないと
    -- `get_active_opts` のフォールバック（唯一のエントリを返す）が働いてしまい、
    -- 共有テーブルに戻しても落ちないテストになる
    local OTHER_HANDLE_ID = "decision-spec-other-handle"

    ---@param handle_id string
    ---@param opts table
    local function activate_as(handle_id, opts)
      permission.set_active_opts(handle_id, vim.tbl_extend("force", { cwd = sandbox_cwd }, opts))
    end

    --- 承認を求める決定（`ask`）は `.res` を書かない。CLIプロセスを kill してから承認UIを
    --- 出す経路で、このspecには kill する実ストリームが無いためそこで止まる。観測できるのは
    --- RPCの戻り値のほうなので、`status` と `.res` の両方を返して呼び出し側に選ばせる
    ---@return {status: string, decision: string?}
    local function decide_as(handle_id, request_id, tool_name, tool_input)
      write_request(request_id, tool_name, tool_input)
      local rpc = permission.check_tool_permission({ request_id = request_id, handle_id = handle_id })

      local decision
      local f = io.open(comm_dir .. "/" .. request_id .. ".res", "r")
      if f then
        local content = f:read("*a")
        f:close()
        decision = vim.json.decode(content).hookSpecificOutput.permissionDecision
      end
      return { status = rpc.status, decision = decision }
    end

    after_each(function()
      permission.clear_active_opts(OTHER_HANDLE_ID)
    end)

    -- `permissions_deny` は必ず明示する。省くと `build_permission_config` が
    -- `config.permissions.deny`（既定で `{ "Bash" }`）に落ち、step 4 の deny が
    -- セッション判定より先に効いてしまう — 何を確かめているのか分からないテストになる
    ---@param session table
    local function chat_opts(session)
      return vim.tbl_extend("force", {
        permissions_allow = { "Read" },
        permissions_deny = {},
        permissions_ask = { "Bash" },
        permission_mode = "default",
      }, session)
    end

    it("does not let one chat's session allow reach another chat", function()
      -- A だけが Bash を承認済み。B は自分の設定どおり Bash を聞く側のまま
      activate_as(HANDLE_ID, chat_opts({ permissions_session_allow = { "Bash" } }))
      activate_as(OTHER_HANDLE_ID, chat_opts({}))

      -- 許可された非MCPツールは "allow" ではなく "defer"（CLI自身のゲートに委ねる）
      local a = decide_as(HANDLE_ID, "req-a-allow", "Bash", { command = "echo hi" })
      assert.equals("allowed", a.status)
      assert.equals("defer", a.decision)

      -- B は承認を出していないので、自分の `permissions_ask` どおり承認待ちになる
      assert.equals("pending", decide_as(OTHER_HANDLE_ID, "req-b-allow", "Bash", { command = "echo hi" }).status)
    end)

    it("does not let one chat's session deny reach another chat", function()
      activate_as(
        HANDLE_ID,
        chat_opts({ permissions_allow = { "Read", "Bash" }, permissions_ask = {}, permissions_session_deny = { "Bash" } })
      )
      activate_as(OTHER_HANDLE_ID, chat_opts({ permissions_allow = { "Read", "Bash" }, permissions_ask = {} }))

      assert.equals("deny", decide_as(HANDLE_ID, "req-a-deny", "Bash", { command = "echo hi" }).decision)

      assert.equals("defer", decide_as(OTHER_HANDLE_ID, "req-b-deny", "Bash", { command = "echo hi" }).decision)
    end)

    it("spends a :once grant on the chat that was given it, not on whoever calls first", function()
      -- `:once` は最初にマッチしたところで消費される。共有テーブルだと、承認を出していない
      -- 別のチャットがそれを食べてしまう — PR #666 の実機確認で踏んだのがこの形
      activate_as(HANDLE_ID, chat_opts({ permissions_session_allow = { "Bash:once" } }))
      activate_as(OTHER_HANDLE_ID, chat_opts({}))

      -- B が先に呼んでも A の1回分は減らない
      assert.equals("pending", decide_as(OTHER_HANDLE_ID, "req-b-once", "Bash", { command = "echo hi" }).status)

      assert.equals("defer", decide_as(HANDLE_ID, "req-a-once-1", "Bash", { command = "echo hi" }).decision)
      -- 使い切ったので2回目は承認待ちに戻る
      assert.equals("pending", decide_as(HANDLE_ID, "req-a-once-2", "Bash", { command = "echo hi" }).status)
    end)
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
