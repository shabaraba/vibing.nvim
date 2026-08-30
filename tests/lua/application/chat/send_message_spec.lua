local SendMessage = require("vibing.application.chat.send_message")

describe("send_message", function()
  describe("execute", function()
    it("propagates the sending chat buffer's number to the adapter opts", function()
      local buf = vim.api.nvim_create_buf(false, true)
      local file_path = vim.fn.tempname() .. ".md"
      vim.api.nvim_buf_set_name(buf, file_path)

      local callbacks = {
        get_bufnr = function()
          return buf
        end,
        get_session_id = function()
          return "test-session"
        end,
        parse_frontmatter = function()
          return {}
        end,
        extract_conversation = function()
          return {}
        end,
        update_filename_from_message = function(_) end,
        start_response = function() end,
        get_session_allow = function()
          return {}
        end,
        get_session_deny = function()
          return {}
        end,
        add_user_section = function() end,
      }

      local captured = {}
      local adapter = {
        supports = function(_, _feature)
          return false
        end,
        execute = function(_, prompt, opts)
          captured.opts = opts
          captured.prompt = prompt
          return { content = "ok" }
        end,
      }

      SendMessage.execute(adapter, callbacks, "hello", {})

      assert.is_not_nil(captured.opts)
      assert.equals(buf, captured.opts.chat_bufnr)

      vim.api.nvim_buf_delete(buf, { force = true })
    end)
  end)

  describe("_handle_response", function()
    local PendingResume = require("vibing.infrastructure.storage.pending_resume")
    local LimitState = require("vibing.infrastructure.storage.limit_state")
    local tmp_root

    before_each(function()
      tmp_root = vim.fn.tempname()
      vim.fn.mkdir(tmp_root, "p")
      LimitState.clear_cache()
    end)

    after_each(function()
      if tmp_root then
        vim.fn.delete(tmp_root, "rf")
      end
    end)

    --- Run one turn through `_handle_response`, against a real, named scratch buffer.
    ---@param response table What the adapter produced: `{ content }`, `{ error }`, ...
    ---@param opts { adapter_name: string|nil, before: fun(chat_path: string)|nil }|nil
    ---  `adapter_name` is the adapter instance's `name` ("claude_cli", "codex_cli", ...), which is
    ---  how the handler tells which backend ran. `before` seeds a store once the chat's path is
    ---  known but before the turn runs.
    ---@return string chat_path The buffer's name, which is the key both stores use.
    local function handle_turn(response, opts)
      opts = opts or {}
      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_name(buf, tmp_root .. "/chat.md")
      -- _handle_response keys the stores by the buffer's name, and Neovim resolves that (on macOS
      -- /var is a symlink to /private/var), so anything seeded here has to use the resolved one.
      local chat_path = vim.api.nvim_buf_get_name(buf)
      if opts.before then
        opts.before(chat_path)
      end

      local callbacks = {
        clear_sending = function() end,
        get_bufnr = function()
          return buf
        end,
        get_session_id = function()
          return nil
        end,
        update_session_id = function(_) end,
        append_chunk = function(_) end,
        add_user_section = function() end,
      }
      local adapter = {
        name = opts.adapter_name,
        supports = function(_, _feature)
          return false
        end,
      }

      SendMessage._handle_response(response, callbacks, adapter, {}, {}, "do the thing")

      vim.api.nvim_buf_delete(buf, { force = true })
      return chat_path
    end

    describe("pending-entry cleanup", function()
      --- Store `entry` for a chat, then run a turn on it that ends with a plain error: not a usage
      --- limit, not a success.
      ---@param entry table Pending entry; its chat_file_path is filled in here.
      ---@return string chat_path The key the entry was stored under.
      local function handle_errored_turn(entry)
        return handle_turn({ error = "stream closed" }, {
          before = function(chat_path)
            entry.chat_file_path = chat_path
            PendingResume.put(entry)
          end,
        })
      end

      it("drops a scheduled entry when the turn ends in a non-limit error", function()
        -- A scheduled request has no stored body — it sends whatever sits in the unsent `## User`
        -- section when it fires. This turn already consumed that section, so an entry outliving it
        -- would later send whatever landed there next (a half-typed follow-up, an approval or
        -- AskUserQuestion option block). Only a *successful* turn used to clear it.
        local chat_path = handle_errored_turn({
          kind = "scheduled",
          resets_at = os.time() + 7200,
          retry_count = 0,
          recorded_at = os.time(),
          state = "waiting",
        })

        assert.is_nil(PendingResume.get(chat_path))
      end)

      it("keeps an auto_resume entry when the turn ends in a non-limit error", function()
        -- The auto_resume contract is untouched: its budget only moves when a limit is observed,
        -- and an errored turn is no evidence the limit lifted.
        local chat_path = handle_errored_turn({
          kind = "auto_resume",
          resets_at = os.time() + 7200,
          retry_count = 1,
          recorded_at = os.time(),
          state = "waiting",
        })

        local entry = PendingResume.get(chat_path)
        assert.is_not_nil(entry)
        assert.equals("waiting", entry.state)
        assert.equals(1, entry.retry_count)

        PendingResume.remove(chat_path)
      end)
    end)

    describe("usage-limit record scoping", function()
      --- Run a successful turn on `adapter_name` against a chat whose project already has a
      --- claude limit on record. Seeding goes through `before` so the record lands in the same
      --- directory the handler resolves — seeding under the unresolved `tmp_root` would leave
      --- both assertions below passing against an empty store.
      ---@param adapter_name string
      ---@return string chat_dir
      local function succeed_under_claude_limit(adapter_name)
        local chat_path = handle_turn({ content = "ok" }, {
          adapter_name = adapter_name,
          before = function(path)
            local dir = vim.fn.fnamemodify(path, ":h")
            LimitState.record({ resets_at = os.time() + 3600 }, dir, "claude")
            assert.is_not_nil(LimitState.get_active(dir, "claude"), "fixture failed to seed the limit")
          end,
        })
        return vim.fn.fnamemodify(chat_path, ":h")
      end

      it("keeps a claude limit on record when a codex turn succeeds", function()
        -- A codex request getting through is no evidence Anthropic's plan limit lifted. Clearing
        -- it would send the next claude message straight into the rejection it was parked to
        -- avoid.
        local chat_dir = succeed_under_claude_limit("codex_cli")

        assert.is_not_nil(LimitState.get_active(chat_dir, "claude"))
      end)

      it("clears the claude limit when a claude turn succeeds", function()
        local chat_dir = succeed_under_claude_limit("claude_cli")

        assert.is_nil(LimitState.load(chat_dir))
      end)
    end)
  end)

  describe("_finalize_snapshot_diff", function()
    -- スナップショット経路が差分を出せなかったとき、呼び出し側は request_diff に退避できないと
    -- いけない。そのため「出力した」か「取れなかった」かを戻り値で返す契約になっている。
    local original

    local function stub_git_snapshot(generate)
      original = package.loaded["vibing.core.utils.git_snapshot"]
      package.loaded["vibing.core.utils.git_snapshot"] = {
        get_root = function()
          return "/repo"
        end,
        generate = generate,
        clear = function() end,
      }
    end

    after_each(function()
      package.loaded["vibing.core.utils.git_snapshot"] = original
      original = nil
    end)

    ---@return table appended append_chunkで書かれた断片
    ---@return table state add_user_sectionが呼ばれたか
    local function callbacks_recording(appended, state)
      return {
        append_chunk = function(chunk)
          table.insert(appended, chunk)
        end,
        add_user_section = function()
          state.user_section = true
        end,
        get_cwd = function()
          return nil
        end,
      }
    end

    it("reports failure and writes nothing when the snapshot could not be taken", function()
      stub_git_snapshot(function()
        return {}, {}, nil, false
      end)
      local appended, state = {}, {}

      local handled =
        SendMessage._finalize_snapshot_diff(callbacks_recording(appended, state), "h1", {})

      assert.is_false(handled)
      assert.same({}, appended)
      assert.is_nil(state.user_section)
    end)

    it("reports success for a turn that genuinely changed nothing", function()
      -- 「変更なし」は失敗ではない。ここでフォールバックすると二重に出力してしまう
      stub_git_snapshot(function()
        return {}, {}, nil, true
      end)
      local appended, state = {}, {}

      local handled =
        SendMessage._finalize_snapshot_diff(callbacks_recording(appended, state), "h2", {})

      assert.is_true(handled)
      assert.same({}, appended)
    end)

    it("writes the file list when the snapshot succeeded", function()
      stub_git_snapshot(function()
        return { "src/a.lua" }, { "/repo/src/a.lua" }, nil, true
      end)
      local appended, state = {}, {}

      local handled =
        SendMessage._finalize_snapshot_diff(callbacks_recording(appended, state), "h3", {})

      assert.is_true(handled)
      assert.is_truthy(table.concat(appended, ""):find("src/a.lua", 1, true))
    end)
  end)

  describe("a turn whose snapshot could not be read", function()
    -- スナップショットが取れず、ツールイベントも無いターンは、退避先が両方とも空になる。
    -- Bashだけで完結したターンではこれが起こりうる。そのままだと「変更なし」と区別が
    -- つかない = Bash由来の変更が黙って消える。この仕組みが無くそうとしている失敗そのもの。
    local original_git_snapshot
    local messages
    local original_notify

    before_each(function()
      messages = {}
      original_notify = vim.notify
      vim.notify = function(msg, level)
        table.insert(messages, { msg = msg, level = level })
      end
    end)

    after_each(function()
      vim.notify = original_notify
      package.loaded["vibing.core.utils.git_snapshot"] = original_git_snapshot
      original_git_snapshot = nil
    end)

    ---@param generate_ok boolean generate が差分を取れたと答えるか
    ---@param root string|nil ベースラインを取れた worktree ルート（nilなら経路に乗らない）
    local function run_turn(generate_ok, root)
      original_git_snapshot = package.loaded["vibing.core.utils.git_snapshot"]
      package.loaded["vibing.core.utils.git_snapshot"] = {
        get_root = function()
          return root
        end,
        had_overlap = function()
          return false
        end,
        worktree_root = function()
          return root
        end,
        generate = function()
          return {}, {}, nil, generate_ok
        end,
        clear = function() end,
      }

      local buf = vim.api.nvim_create_buf(false, true)
      local callbacks = {
        clear_sending = function() end,
        get_bufnr = function()
          return buf
        end,
        get_session_id = function()
          return nil
        end,
        update_session_id = function(_) end,
        append_chunk = function(_) end,
        add_user_section = function() end,
        get_cwd = function()
          return nil
        end,
      }
      local adapter = {
        supports = function(_, _feature)
          return false
        end,
      }

      SendMessage._handle_response({ content = "done" }, callbacks, adapter, {}, {}, "msg")
      vim.api.nvim_buf_delete(buf, { force = true })
    end

    it("warns rather than reading as an unchanged turn", function()
      run_turn(false, "/repo")

      assert.equals(1, #messages)
      assert.equals(vim.log.levels.WARN, messages[1].level)
      assert.is_truthy(messages[1].msg:find("snapshot failed", 1, true))
    end)

    it("stays quiet for a turn that genuinely changed nothing", function()
      run_turn(true, "/repo")

      assert.equals(0, #messages)
    end)

    it("stays quiet when the snapshot path was never taken", function()
      -- git管理外のworking_dir。スナップショットを試してすらいないので、警告する材料が無い
      run_turn(false, nil)

      assert.equals(0, #messages)
    end)
  end)

  describe("choosing between the snapshot and the fallback", function()
    -- 経路選択は2つの重なり信号の **OR** で、どちらの信号も単体では
    -- git_snapshot_spec / active_stream_registry_spec 側で手厚くテストされている。
    -- テストが無かったのは、その2つを結ぶ send_message 側の条件式そのもの。
    -- ここを `and` に書き違えても条件を反転させても、他のspecは全部通ってしまう。
    local ASR = require("vibing.infrastructure.adapter.modules.active_stream_registry")

    local saved = {}
    local original_find
    local called

    ---@param opts { root: string|nil, had_overlap: boolean, other_stream: boolean }
    ---@return "snapshot"|"fallback"|"neither" どちらの generate が呼ばれたか
    local function route(opts)
      called = {}

      saved["vibing.core.utils.git_snapshot"] = package.loaded["vibing.core.utils.git_snapshot"]
      package.loaded["vibing.core.utils.git_snapshot"] = {
        get_root = function()
          return opts.root
        end,
        had_overlap = function()
          return opts.had_overlap
        end,
        worktree_root = function()
          return opts.root
        end,
        generate = function()
          called.snapshot = true
          -- 差分が取れた体で返す。取れなかった場合の分岐は別のdescribeが持っている
          return { "a.lua" }, { "/repo/a.lua" }, nil, true
        end,
        clear = function() end,
      }

      saved["vibing.core.utils.request_diff"] = package.loaded["vibing.core.utils.request_diff"]
      package.loaded["vibing.core.utils.request_diff"] = {
        generate = function()
          called.fallback = true
          return { "a.lua" }, { "/repo/a.lua" }, nil
        end,
        clear = function() end,
        capture = function() end,
      }

      -- ActiveStreamRegistry は send_message のトップレベルでrequireされている（upvalue）ので、
      -- package.loaded を差し替えても届かない。実物のテーブルの関数だけ差し替える
      original_find = ASR.find_other_active_for_worktree
      ASR.find_other_active_for_worktree = function()
        return opts.other_stream and { handle_id = "other" } or nil
      end

      local buf = vim.api.nvim_create_buf(false, true)
      local callbacks = {
        clear_sending = function() end,
        get_bufnr = function()
          return buf
        end,
        get_session_id = function()
          return nil
        end,
        update_session_id = function(_) end,
        append_chunk = function(_) end,
        add_user_section = function() end,
        get_cwd = function()
          return opts.root
        end,
      }
      local adapter = {
        supports = function(_, _feature)
          return false
        end,
      }

      -- ツールイベントが1件ある状態にする。フォールバック側はこれが空だと
      -- 「変更なし」分岐に落ちて generate まで届かない
      SendMessage._handle_response(
        { content = "done" },
        callbacks,
        adapter,
        {},
        { ["/repo/a.lua"] = true },
        "msg"
      )
      vim.api.nvim_buf_delete(buf, { force = true })

      if called.snapshot then
        return "snapshot"
      elseif called.fallback then
        return "fallback"
      end
      return "neither"
    end

    after_each(function()
      if original_find then
        ASR.find_other_active_for_worktree = original_find
        original_find = nil
      end
      for name, module in pairs(saved) do
        package.loaded[name] = module
      end
      saved = {}
    end)

    it("takes the snapshot when neither signal reports an overlap", function()
      assert.equals(
        "snapshot",
        route({ root = "/repo", had_overlap = false, other_stream = false })
      )
    end)

    it("falls back when the baseline recorded an overlapping window", function()
      -- 相手が先に終わっていてレジストリには何も残っていない、という一番効く形
      assert.equals(
        "fallback",
        route({ root = "/repo", had_overlap = true, other_stream = false })
      )
    end)

    it("falls back when a stream without a baseline is writing in the same worktree", function()
      assert.equals(
        "fallback",
        route({ root = "/repo", had_overlap = false, other_stream = true })
      )
    end)

    it("falls back when both signals fire", function()
      assert.equals("fallback", route({ root = "/repo", had_overlap = true, other_stream = true }))
    end)

    it("falls back outside a git repository, without asking either signal", function()
      assert.equals("fallback", route({ root = nil, had_overlap = false, other_stream = false }))
    end)
  end)

  describe("_warn_removed_frontmatter", function()
    local messages
    local original_notify

    before_each(function()
      SendMessage._reset_removed_frontmatter_warnings()
      messages = {}
      original_notify = vim.notify
      vim.notify = function(msg, level)
        table.insert(messages, { msg = msg, level = level })
      end
    end)

    after_each(function()
      vim.notify = original_notify
      SendMessage._reset_removed_frontmatter_warnings()
    end)

    it("says nothing for frontmatter that carries no removed key", function()
      SendMessage._warn_removed_frontmatter({ model = "sonnet" })

      assert.equals(0, #messages)
    end)

    it("names every removed key it found, once", function()
      SendMessage._warn_removed_frontmatter({ mote_dirs = { "/repo" }, mote_cwd = "/repo" })
      SendMessage._warn_removed_frontmatter({ mote_dirs = { "/repo" }, mote_cwd = "/repo" })

      assert.equals(1, #messages)
      assert.is_truthy(messages[1].msg:find("mote_dirs", 1, true))
      assert.is_truthy(messages[1].msg:find("mote_cwd", 1, true))
      assert.equals(vim.log.levels.WARN, messages[1].level)
    end)

    it("tolerates a missing frontmatter table", function()
      SendMessage._warn_removed_frontmatter(nil)

      assert.equals(0, #messages)
    end)
  end)
end)
