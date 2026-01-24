---@class Vibing.Presentation.DailySummaryController

local UseCase = require("vibing.application.daily_summary.use_case")
local notify = require("vibing.core.utils.notify")

local M = {}

---@param args string
---@param include_all boolean
local function handle_summary(args, include_all)
  local date, err = UseCase.validate_date(args)
  if not date then
    notify.error(err, "Daily Summary")
    return
  end
  UseCase.generate_summary(date, include_all)
end

---@param args string
function M.handle_daily_summary(args)
  handle_summary(args, false)
end

---@param args string
function M.handle_daily_summary_all(args)
  handle_summary(args, true)
end

return M
