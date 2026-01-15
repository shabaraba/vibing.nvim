---@class Vibing.Domain.Mention.Repository
---メンションリポジトリのインターフェース（抽象）
---Infrastructure層で実装される
local M = {}

---リポジトリインターフェースの定義
---実装クラスはこれらのメソッドを提供する必要がある
M.interface = {
  ---メンションを保存
  ---@param mention Vibing.Domain.Mention.Entity
  save = function(mention) end,

  ---特定Squadの未処理メンションを取得
  ---@param squad_name string
  ---@return Vibing.Domain.Mention.Entity[]
  find_unprocessed_by_squad = function(squad_name) end,

  ---メンションを処理済みにする
  ---@param mention_id string MentionId.value
  mark_processed = function(mention_id) end,

  ---特定Squadの全メンションを処理済みにする
  ---@param squad_name string
  mark_all_processed_by_squad = function(squad_name) end,

  ---全メンションをクリア（テスト用）
  clear_all = function() end,
}

return M
