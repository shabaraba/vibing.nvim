---タスクキュー管理モジュール
---インラインアクションのタスクをキューに追加し、直列実行を管理

local QueueManager = require("vibing.application.inline.queue_manager")
local notify = require("vibing.core.utils.notify")

---@class Vibing.TaskQueueModule
local M = {}

---タスクをキューに追加して処理を開始
---@param task table タスクオブジェクト { id: string, execute: function(done) }
function M.enqueue(task)
  local pos = QueueManager.enqueue(task)

  if QueueManager.is_processing() and pos > 1 then
    notify.info(string.format("Task queued (%d tasks waiting)", pos - 1), "Inline")
  elseif pos > 1 then
    notify.info(string.format("Executing task (%d more in queue)...", pos - 1), "Inline")
  end

  QueueManager.process()
end

---タスクオブジェクトを作成
---@param id string タスクID
---@param execute_fn function(done: function) 実行関数
---@return table Task object
function M.create_task(id, execute_fn)
  return {
    id = id,
    execute = execute_fn,
  }
end

---タスクIDを生成
---@param prefix string タスクIDのプレフィックス（action名など）
---@return string
function M.generate_id(prefix)
  return string.format("%s-%d", prefix, vim.loop.hrtime())
end

return M
