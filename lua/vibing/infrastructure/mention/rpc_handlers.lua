---@class Vibing.Infrastructure.Mention.RpcHandlers
---メンション関連のRPCハンドラー
---Application層のユースケースを呼び出す
local M = {}

local MentionUseCase = require("vibing.application.mention.use_case")
local InterruptionChecker = require("vibing.application.mention.services.interruption_checker")

---現在のバッファのSquad名を取得
---@return string? squad_name
local function get_current_squad_name()
  local bufnr = vim.api.nvim_get_current_buf()
  return vim.b[bufnr].vibing_squad_name
end

---メンション情報を取得（統合API - canUseTool用）
---@param params table { squad_name?: string }
---@return table { has_mentions: boolean, count: number, squad_name: string, mentions: table[] }
function M.get_mention_info(params)
  local squad_name = params.squad_name or get_current_squad_name()

  if not squad_name then
    return {
      has_mentions = false,
      count = 0,
      squad_name = "",
      mentions = {},
      error = "No squad_name provided and no current squad found",
    }
  end

  return InterruptionChecker.get_interruption_info(squad_name)
end

---メンションを処理済みにする
---@param params table { mention_id: string }
---@return table { success: boolean }
function M.mark_mention_processed(params)
  if not params.mention_id then
    return { success = false, error = "mention_id is required" }
  end

  MentionUseCase.mark_mention_processed(params.mention_id)
  return { success = true }
end

---特定Squadの全メンションを処理済みにする
---@param params table { squad_name?: string }
---@return table { success: boolean, squad_name: string }
function M.mark_all_mentions_processed(params)
  local squad_name = params.squad_name or get_current_squad_name()

  if not squad_name then
    return { success = false, squad_name = "", error = "No squad_name provided and no current squad found" }
  end

  MentionUseCase.mark_all_processed(squad_name)
  return { success = true, squad_name = squad_name }
end

---メンションを記録（他Squadからの通知用）
---宛先Squadが停止中の場合は自動で通知を送信
---@param params table { from_squad_name: string, to_squad_name: string, content: string }
---@return table { success: boolean, mention_id?: string, notified?: boolean }
function M.record_mention(params)
  if not params.from_squad_name or params.from_squad_name == "" then
    return { success = false, error = "from_squad_name is required" }
  end
  if not params.to_squad_name or params.to_squad_name == "" then
    return { success = false, error = "to_squad_name is required" }
  end
  if not params.content then
    return { success = false, error = "content is required" }
  end

  -- メンションを記録
  local mention = MentionUseCase.record_mention(
    params.from_squad_name,
    params.to_squad_name,
    params.content
  )

  -- 宛先が停止中なら通知を送信（vim.scheduleで非同期実行）
  local notified = false
  vim.schedule(function()
    local Notifier = require("vibing.application.mention.services.notifier")
    Notifier.notify_if_idle(params.to_squad_name, params.from_squad_name, params.content)
  end)

  return { success = true, mention_id = mention.id.value, notified = notified }
end

return M
