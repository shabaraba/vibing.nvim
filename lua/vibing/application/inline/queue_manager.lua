---@class Vibing.QueueTask
---@field id string Unique task identifier
---@field execute fun(done: fun()) Task execution function
---@field cancel? fun() Optional cancel function

---@class Vibing.QueueManager
local M = {}

---@type Vibing.QueueTask[]
local queue = {}
---@type boolean
local processing = false
---@type Vibing.QueueTask|nil
local current_task = nil

---Add a task to the queue
---@param task Vibing.QueueTask Task to enqueue
---@return integer position Position in queue (1-indexed)
function M.enqueue(task)
  table.insert(queue, task)
  return #queue
end

---Get the current queue size
---@return integer size Number of tasks in queue
function M.size()
  return #queue
end

---Check if a task is currently being processed
---@return boolean processing True if a task is being processed
function M.is_processing()
  return processing
end

---Clear the queue and reset processing state
function M.clear()
  queue = {}
  processing = false
  current_task = nil
end

---Get the currently executing task
---@return Vibing.QueueTask|nil current_task The current task or nil
function M.get_current()
  return current_task
end

local function process_next()
  if #queue == 0 then
    processing = false
    current_task = nil
    return
  end

  current_task = table.remove(queue, 1)

  local function done()
    vim.schedule(function()
      process_next()
    end)
  end

  local ok, err = pcall(function()
    current_task.execute(done)
  end)

  if not ok then
    vim.schedule(function()
      vim.notify("Task error: " .. tostring(err), vim.log.levels.ERROR)
      process_next()
    end)
  end
end

---Start processing the queue
function M.process()
  if processing then
    return
  end

  if #queue == 0 then
    return
  end

  processing = true
  process_next()
end

---Cancel the currently executing task
function M.cancel_current()
  if current_task and current_task.cancel then
    current_task.cancel()
  end
end

---Cancel all tasks (current and queued)
function M.cancel_all()
  M.cancel_current()
  queue = {}
  processing = false
  current_task = nil
end

---Get queue status information
---@return {size: integer, processing: boolean, current_id: string|nil} info Queue information
function M.get_queue_info()
  return {
    size = #queue,
    processing = processing,
    current_id = current_task and current_task.id or nil,
  }
end

return M
