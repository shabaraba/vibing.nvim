---@class Vibing.Application.Link.RenameSync
---チャットファイルが改名されたときに、そのパスを記録している側を全部書き換える。
---
---リンクの記録は表示パスなので、改名したチャットを指している frontmatter と daily summary の
---本文は、改名と同じ操作の中で直さないと黙って切れる。bufnr は再起動で別のものを指し、
---ファイル名は改名で変わるので、関係が意味を持ち続ける場所は frontmatter のパスしかない。
local M = {}

local ChatLinks = require("vibing.core.constants.chat_links")
local notify = require("vibing.core.utils.notify")
local SyncManager = require("vibing.application.link.sync_manager")

---チャット間リンクを追従させるスキャナーを、リンクフィールドの定義から組み立てる
---
---構成をここに書き下さないのは、フィールドが1つ増えたときに**黙って**壊れるため。
---スキャナーの無いフィールドは、改名でリンクが切れてもエラーを出さない
---@return Vibing.Infrastructure.Link.Scanner[]
local function chat_link_scanners()
  local ForkedChatScanner = require("vibing.infrastructure.link.forked_chat_scanner")
  local OrchestrationChatScanner = require("vibing.infrastructure.link.orchestration_chat_scanner")

  local scanners = {}
  for _, field in ipairs(ChatLinks.FIELDS) do
    if field.shape == "scalar" then
      table.insert(scanners, ForkedChatScanner.new(field.key))
    end
  end
  -- リスト型のキーは1本のスキャナーが全部見る（`OrchestrationChatScanner` のコメント参照）
  if #ChatLinks.keys_of_shape("list") > 0 then
    table.insert(scanners, OrchestrationChatScanner.new())
  end

  return scanners
end

---@param old_path string
---@param new_path string
---@param save_dir string チャットの保存ディレクトリ
---@param daily_dir string daily summaryの保存ディレクトリ
function M.apply(old_path, new_path, save_dir, daily_dir)
  local DailySummaryScanner = require("vibing.infrastructure.link.daily_summary_scanner")

  local daily_result = SyncManager.sync_links(old_path, new_path, { DailySummaryScanner.new() }, daily_dir)

  -- チャット間リンクはベースディレクトリが同じなので、1回の呼び出しにまとめられる
  local chat_result = SyncManager.sync_links(old_path, new_path, chat_link_scanners(), save_dir)

  local updated = daily_result.updated + chat_result.updated
  local failed = daily_result.failed + chat_result.failed

  if updated > 0 then
    notify.info(string.format("Updated %d linked file(s)", updated), "Link Sync")
  end
  if failed > 0 then
    notify.warn(string.format("Failed to update %d file(s)", failed), "Link Sync")
  end
end

return M
