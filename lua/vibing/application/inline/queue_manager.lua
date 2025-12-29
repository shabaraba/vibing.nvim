local M = {}

local queue = {}
local processing = false
local current_task = nil

function M.enqueue(task)
  table.insert(queue, task)
  return #queue
end

function M.size()
  return #queue
end

function M.is_processing()
  return processing
end

function M.clear()
  queue = {}
  processing = false
  current_task = nil
end

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

function M.cancel_current()
  if current_task and current_task.cancel then
    current_task.cancel()
  end
end

function M.cancel_all()
  M.cancel_current()
  queue = {}
end

function M.get_queue_info()
  return {
    size = #queue,
    processing = processing,
    current_id = current_task and current_task.id or nil,
  }
end

return M
