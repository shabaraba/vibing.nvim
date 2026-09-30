---@diagnostic disable: undefined-field
local BackgroundTasks = require("vibing.infrastructure.adapter.modules.background_tasks")

describe("adapter.background_tasks", function()
  local function started(context, task_id, description)
    BackgroundTasks.started(context, { task_id = task_id, description = description })
  end

  describe("what never reported back", function()
    it("lists a task that was started and never notified", function()
      local context = {}
      started(context, "a1", "read the logs")
      local unreported = BackgroundTasks.unreported(context)
      assert.equals(1, #unreported)
      assert.equals("a1", unreported[1].task_id)
      assert.equals("read the logs", unreported[1].description)
    end)

    it("drops a task once its notification arrives", function()
      local context = {}
      started(context, "a1", "read the logs")
      BackgroundTasks.done(context, { task_id = "a1" })
      assert.same({}, BackgroundTasks.unreported(context))
    end)

    -- The whole point of the recovery path: some notifications land and some do not, and only the
    -- ones that did not are recovered from disk.
    it("separates the notified from the unnotified", function()
      local context = {}
      started(context, "a1", "one")
      started(context, "a2", "two")
      started(context, "a3", "three")
      BackgroundTasks.done(context, { task_id = "a2" })
      local ids = vim.tbl_map(function(t)
        return t.task_id
      end, BackgroundTasks.unreported(context))
      assert.same({ "a1", "a3" }, ids)
    end)

    it("is empty on a turn that launched nothing", function()
      assert.same({}, BackgroundTasks.unreported({}))
    end)
  end)

  -- #820: the outstanding set is what wakes the chat, so it has to survive every reason recovery
  -- might come back with nothing. Recovery finding text is a bonus, not the trigger.
  describe("what a closing turn reports", function()
    it("reports the outstanding set even when recovery finds nothing", function()
      local context = {}
      started(context, "a1", "one")
      local unreported, recovered = BackgroundTasks.report(context, function()
        return {}
      end)
      assert.equals(1, #unreported)
      assert.same({}, recovered)
    end)

    -- A backend with no recovery hook still has a chat that nothing else will wake.
    it("reports the outstanding set on a backend that cannot recover", function()
      local context = {}
      started(context, "a1", "one")
      local unreported, recovered = BackgroundTasks.report(context, nil)
      assert.equals(1, #unreported)
      assert.same({}, recovered)
    end)

    -- The recovery hook is the descriptor's own function, called with the argument list it declares
    -- (`unreported, cwd, session_id`) — so a change to that signature cannot silently pass nil.
    it("hands the outstanding set and the location to the recovery it was given", function()
      local context = {}
      started(context, "a1", "one")
      started(context, "a2", "two")
      local seen, seen_cwd, seen_session
      local _, recovered = BackgroundTasks.report(context, function(list, cwd, session_id)
        seen, seen_cwd, seen_session = list, cwd, session_id
        return { { task_id = "a2", text = "done" } }
      end, "/tmp/repo", "sess-1")
      assert.same({ "a1", "a2" }, vim.tbl_map(function(t)
        return t.task_id
      end, seen))
      assert.equals("/tmp/repo", seen_cwd)
      assert.equals("sess-1", seen_session)
      assert.equals("a2", recovered[1].task_id)
    end)

    -- Nothing outstanding must not call recovery at all: it would go looking on disk on every
    -- ordinary turn, which is every turn.
    it("never calls recovery when nothing is outstanding", function()
      local called = false
      local unreported, recovered = BackgroundTasks.report({}, function()
        called = true
        return {}
      end)
      assert.is_false(called)
      assert.same({}, unreported)
      assert.same({}, recovered)
    end)
  end)

  describe("handing the launch back to the completion", function()
    -- The completion line names the task by the brief it was launched with, and the notification
    -- does not carry one.
    it("returns what the launch recorded", function()
      local context = {}
      started(context, "a1", "read the logs")
      assert.equals("read the logs", BackgroundTasks.done(context, { task_id = "a1" }).description)
    end)

    -- A notification for a task whose start was missed must not resurrect it as an entry, or the
    -- recovery path would go looking for a transcript nobody launched.
    it("invents nothing from a notification alone", function()
      local context = {}
      assert.is_nil(BackgroundTasks.done(context, { task_id = "ghost" }))
      assert.same({}, BackgroundTasks.unreported(context))
    end)
  end)
end)
