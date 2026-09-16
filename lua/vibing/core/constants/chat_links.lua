---@class Vibing.Core.ChatLinkConstants
---1つのチャットが他のチャットを名指す frontmatter フィールドの唯一の定義。
---
---`shape` は値の形であり、そのまま**書き換え方**でもある。`scalar` はキーごと差し替えられる
---（`ForkedChatScanner`）が、`list` に同じことをすると他の要素が全部消えるので、該当する1要素
---だけを差し替える（`OrchestrationChatScanner`）。
---
---1箇所にまとめてあるのは、欠けたときにどれも**黙って**壊れるため。`rename_sync` の作る
---スキャナーに無いフィールドは、リネームでリンクが切れてもエラーにならない。`linked_chats`
---から漏れたフィールドは、ただ小さい連結成分を返すだけで「リンク先が無かった」と区別が付かない。
---
---`orchestrated` の向き（親→子）や `forked_from` の向き（子→親）はここでは持たない。向きを
---要るのは `orchestration_tree` だけで、そこはキーを名指しで読む。`linked_chats` は向きを
---落として網として辿るので、どのフィールドかを区別しない。
local M = {}

---@class Vibing.Core.ChatLinkField
---@field key string frontmatterのキー
---@field shape "scalar"|"list" 値の形

---@type Vibing.Core.ChatLinkField[]
M.FIELDS = {
  { key = "forked_from", shape = "scalar" },
  { key = "continued_from", shape = "scalar" },
  { key = "orchestrated", shape = "list" },
  { key = "orchestrated_by", shape = "list" },
}

---@param shape "scalar"|"list"
---@return string[]
function M.keys_of_shape(shape)
  local keys = {}
  for _, field in ipairs(M.FIELDS) do
    if field.shape == shape then
      table.insert(keys, field.key)
    end
  end
  return keys
end

return M
