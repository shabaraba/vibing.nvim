local queue_manager = require("vibing.application.inline.queue_manager")

describe("queue_manager", function()
  before_each(function()
    queue_manager.clear()
  end)

  describe("enqueue task (UT-QM-001)", function()
    it("should enqueue a task and return position", function()
      local task = { id = "task1", execute = function() end }
      local pos = queue_manager.enqueue(task)
      assert.equals(1, pos)
    end)

    it("should increment position for multiple tasks", function()
      local task1 = { id = "task1", execute = function() end }
      local task2 = { id = "task2", execute = function() end }

      local pos1 = queue_manager.enqueue(task1)
      local pos2 = queue_manager.enqueue(task2)

      assert.equals(1, pos1)
      assert.equals(2, pos2)
    end)

    it("should return queue size", function()
      queue_manager.enqueue({ id = "1", execute = function() end })
      queue_manager.enqueue({ id = "2", execute = function() end })
      queue_manager.enqueue({ id = "3", execute = function() end })

      assert.equals(3, queue_manager.size())
    end)
  end)

  describe("serial execution (UT-QM-002)", function()
    it("should execute tasks in FIFO order", function()
      local order = {}

      queue_manager.enqueue({
        id = "1",
        execute = function(done)
          table.insert(order, "1")
          done()
        end,
      })
      queue_manager.enqueue({
        id = "2",
        execute = function(done)
          table.insert(order, "2")
          done()
        end,
      })
      queue_manager.enqueue({
        id = "3",
        execute = function(done)
          table.insert(order, "3")
          done()
        end,
      })

      queue_manager.process()
      vim.wait(100, function()
        return #order == 3
      end)

      assert.same({ "1", "2", "3" }, order)
    end)
  end)

  describe("error isolation (UT-QM-003)", function()
    it("should continue after task error", function()
      local task2_ran = false

      queue_manager.enqueue({
        id = "1",
        execute = function(done)
          error("intentional error")
        end,
      })
      queue_manager.enqueue({
        id = "2",
        execute = function(done)
          task2_ran = true
          done()
        end,
      })

      queue_manager.process()
      vim.wait(200, function()
        return task2_ran
      end)

      assert.is_true(task2_ran)
    end)
  end)

  describe("concurrent prevention (UT-QM-004)", function()
    it("should not run tasks concurrently", function()
      local concurrent_detected = false
      local executing = false

      queue_manager.enqueue({
        id = "1",
        execute = function(done)
          executing = true
          vim.defer_fn(function()
            executing = false
            done()
          end, 50)
        end,
      })
      queue_manager.enqueue({
        id = "2",
        execute = function(done)
          if executing then
            concurrent_detected = true
          end
          done()
        end,
      })

      queue_manager.process()
      vim.wait(200, function()
        return queue_manager.size() == 0
      end)

      assert.is_false(concurrent_detected)
    end)
  end)

  describe("is_processing", function()
    it("should return true while processing", function()
      local checked_during = false

      queue_manager.enqueue({
        id = "1",
        execute = function(done)
          checked_during = queue_manager.is_processing()
          done()
        end,
      })

      queue_manager.process()
      vim.wait(100, function()
        return queue_manager.size() == 0
      end)

      assert.is_true(checked_during)
    end)

    it("should return false when idle", function()
      assert.is_false(queue_manager.is_processing())
    end)
  end)
end)
