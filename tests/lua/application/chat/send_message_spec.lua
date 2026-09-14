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

    -- The choice list is only staged here; add_user_section() at the end of _handle_response is
    -- what renders it, and cancel() queues that completion. Deferring the staging by one tick put
    -- it after that completion, so the questions were consumed as nil and the turn ended with the
    -- reply cut short and nothing to answer (#649).
    it("stages AskUserQuestion choices synchronously rather than a tick later", function()
      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_name(buf, vim.fn.tempname() .. ".md")

      local staged
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
        insert_choices = function(questions)
          staged = questions
        end,
      }

      local captured = {}
      local adapter = {
        supports = function(_, _feature)
          return false
        end,
        execute = function(_, _prompt, opts)
          captured.opts = opts
          return { content = "ok" }
        end,
      }

      SendMessage.execute(adapter, callbacks, "hello", {})

      local questions = { { question = "Which one?", options = { { label = "a" } } } }
      captured.opts.on_insert_choices(questions)
      -- Asserted without running the event loop: a vim.schedule here would leave this nil.
      assert.same(questions, staged)

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
    ---@return string[] appended chunks written to the chat buffer
    ---@return boolean marked_error whether the turn was recorded as having ended in an error
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

      local appended = {}
      local marked_error = false
      local callbacks = {
        mark_turn_error = function()
          marked_error = true
        end,
        clear_sending = function() end,
        get_bufnr = function()
          return buf
        end,
        get_session_id = function()
          return nil
        end,
        update_session_id = function(_) end,
        append_chunk = function(chunk)
          table.insert(appended, chunk)
        end,
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
      return chat_path, appended, marked_error
    end

    describe("recording why the turn stopped", function()
      -- `chat_status` reports this as `error`, and `completion_notifier` treats that as a stop
      -- worth waking the parent for. Anything that is really still *waiting* must stay out of it.

      it("marks a turn that ended with an ordinary error", function()
        local _, _, marked_error = handle_turn({ error = "boom" })

        assert.is_true(marked_error)
      end)

      it("does not mark a turn the usage limit rejected", function()
        -- The limit branch has already parked this turn (scheduled send or auto-resume), so it is
        -- a "waiting" state, not a failure. `response.error` still carries the limit text —
        -- `RateLimit.merge` reads it and does not clear it — so without the guard every parked
        -- turn reports `error` and the orchestrator reads a healthy worker as failed.
        local _, _, marked_error = handle_turn({
          error = "Claude AI usage limit reached",
          _rate_limit_info = { rejected = true, resets_at = os.time() + 3600 },
        })

        assert.is_false(marked_error)
      end)

      it("does not mark a turn that was cancelled to ask or to request approval", function()
        local _, _, marked_error = handle_turn({ error = "Cancelled", _cancelled = true })

        assert.is_false(marked_error)
      end)
    end)

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

    it("does not render an explicit cancellation as a chat error", function()
      local _, appended = handle_turn({ error = "Cancelled", _cancelled = true, _handle_id = "h-cancel" })

      assert.is_nil(table.concat(appended, ""):find("**Error:** Cancelled", 1, true))
    end)
  end)

  describe("_finalize_snapshot_diff", function()
    -- スナップショット経路が差分を出せなかったとき、呼び出し側は request_diff に退避できないと
    -- いけない。そのため「出力した」か「取れなかった」かを戻り値で返す契約になっている。
    local original

    local function stub_git_snapshot(generate, root)
      original = package.loaded["vibing.core.utils.git_snapshot"]
      package.loaded["vibing.core.utils.git_snapshot"] = {
        get_root = function()
          return root or "/repo"
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

    it("mixes a synthesized section for a gitignored file into the written patch", function()
      -- gitignore対象のファイルはツリー差分に現れない（#735）。extra_only として返ってきた
      -- 分を request_diff の退避から合成し、このターンのpatchファイルに載せる
      local RequestDiff = require("vibing.core.utils.request_diff")
      local root = vim.fn.fnamemodify(vim.fn.tempname(), ":p"):gsub("/$", "")
      vim.fn.mkdir(root .. "/ignored", "p")
      local file = root .. "/ignored/out.txt"
      local f = assert(io.open(file, "w"))
      f:write("before\n")
      f:close()
      RequestDiff.capture("h4", "Edit", { file_path = file })
      f = assert(io.open(file, "w"))
      f:write("after\n")
      f:close()

      stub_git_snapshot(function()
        return { "ignored/out.txt" }, { file }, nil, true, { file }
      end, root)
      local appended, state = {}, {}

      local handled =
        SendMessage._finalize_snapshot_diff(callbacks_recording(appended, state), "h4", {})
      RequestDiff.clear("h4")

      assert.is_true(handled)
      local out = table.concat(appended, "")
      -- patch行の形は `patch_finder` が唯一の読み手。ここで別に書くと両者が黙ってずれる
      local PatchFinder = require("vibing.presentation.chat.modules.patch_finder")
      local patch_path
      for _, line in ipairs(vim.split(out, "\n", { plain = true })) do
        patch_path = patch_path or PatchFinder.parse_patch_line(line)
      end
      assert.is_truthy(patch_path, "no patch annotation written: " .. out)
      local pf = assert(io.open(patch_path, "r"))
      local content = pf:read("*a")
      pf:close()
      assert.is_truthy(content:find("diff --git a/ignored/out.txt b/ignored/out.txt", 1, true))
      assert.is_truthy(content:find("+after", 1, true))
      vim.fn.delete(root, "rf")
    end)
  end)

  describe("_supplement_ignored_files", function()
    -- ツリー差分に現れなかった extra_paths 由来のファイル（#735）の扱い。退避があれば
    -- hunkを合成してpatchに継ぎ足し、退避も無ければ「patchが無い」ことを通知する
    local RequestDiff = require("vibing.core.utils.request_diff")
    local tmp_dir
    local messages
    local original_notify

    local function write(path, content)
      vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
      local f = assert(io.open(path, "w"))
      f:write(content)
      f:close()
    end

    before_each(function()
      tmp_dir = vim.fn.fnamemodify(vim.fn.tempname(), ":p"):gsub("/$", "")
      vim.fn.mkdir(tmp_dir, "p")
      messages = {}
      original_notify = vim.notify
      vim.notify = function(msg, level)
        table.insert(messages, { msg = msg, level = level })
      end
    end)

    after_each(function()
      vim.notify = original_notify
      vim.fn.delete(tmp_dir, "rf")
    end)

    it("builds a patch from the backup when the snapshot produced none", function()
      local file = tmp_dir .. "/ignored/gen.txt"
      write(file, "before\n")
      RequestDiff.capture("h-sup1", "Edit", { file_path = file })
      write(file, "after\n")

      local patch = SendMessage._supplement_ignored_files("h-sup1", tmp_dir, nil, { file })
      RequestDiff.clear("h-sup1")

      assert.is_truthy(patch)
      assert.equals("# vibing-request-diff base: " .. tmp_dir, patch:match("^[^\n]+"))
      assert.is_truthy(patch:find("+after", 1, true))
      assert.equals(0, #messages)
    end)

    it("appends after the snapshot patch when both exist", function()
      local file = tmp_dir .. "/ignored/gen.txt"
      write(file, "before\n")
      RequestDiff.capture("h-sup2", "Edit", { file_path = file })
      write(file, "after\n")

      local head = "# vibing-request-diff base: "
        .. tmp_dir
        .. "\ndiff --git a/tracked.txt b/tracked.txt\n--- a/tracked.txt\n+++ b/tracked.txt\n@@ -1 +1 @@\n-x\n+y\n"
      local patch = SendMessage._supplement_ignored_files("h-sup2", tmp_dir, head, { file })
      RequestDiff.clear("h-sup2")

      local tracked_pos = patch:find("a/tracked.txt", 1, true)
      local ignored_pos = patch:find("a/ignored/gen.txt", 1, true)
      assert.is_truthy(tracked_pos)
      assert.is_truthy(ignored_pos)
      assert.is_true(tracked_pos < ignored_pos)
    end)

    it("warns for a listed file whose changes exist nowhere", function()
      -- Bash由来・codexのapply_patch由来の変更は退避が無く合成できない。黙って流すと
      -- 「一覧に載るのにpatchが無い」が warning すら無しに再発する
      local file = tmp_dir .. "/ignored/bash.txt"
      write(file, "x\n")

      local patch = SendMessage._supplement_ignored_files("h-sup3", tmp_dir, nil, { file })

      assert.is_nil(patch)
      assert.equals(1, #messages)
      assert.equals(vim.log.levels.WARN, messages[1].level)
      assert.is_truthy(messages[1].msg:find("ignored/bash.txt", 1, true))
    end)

    it("passes the patch through untouched when the tree diff covered everything", function()
      local patch = SendMessage._supplement_ignored_files("h-sup4", tmp_dir, "existing", {})

      assert.equals("existing", patch)
      assert.equals(0, #messages)
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
