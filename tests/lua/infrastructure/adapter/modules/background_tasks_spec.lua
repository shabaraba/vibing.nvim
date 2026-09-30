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
