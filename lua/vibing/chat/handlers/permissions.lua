local notify = require("vibing.utils.notify")
local permission_builder = require("vibing.ui.permission_builder")

---/permissionsコマンドハンドラー（/permエイリアス）
---チャット内で/permissions または /permを実行した際に呼び出される
---Permission Builderを起動し、対話的に権限設定を追加
---ループでツール選択→allow/deny選択→Bashパターン選択（該当時）→frontmatter更新を繰り返す
---@param args string[] コマンド引数（使用しない）
---@param chat_buffer Vibing.ChatBuffer コマンドを実行したチャットバッファ
---@return boolean 常にtrue（キャンセル時も含む）
return function(args, chat_buffer)
  if not chat_buffer then
    notify.error("No chat buffer")
    return false
  end

  local function run_builder()
    permission_builder.show_picker(chat_buffer, function(tool)
      if not tool then
        return
      end

      permission_builder.prompt_permission_type(tool.name, function(permission_type)
        if not permission_type then
          return
        end

        permission_builder.handle_bash_pattern_selection(tool, permission_type, function(permission_string)
          if not permission_string then
            return
          end

          local key = permission_type == "allow" and "permissions_allow" or "permissions_deny"
          local success = chat_buffer:update_frontmatter_list(key, permission_string, "add")

          if success then
            notify.info(
              string.format("Added '%s' to %s", permission_string, key)
            )
            vim.defer_fn(function()
              run_builder()
            end, 100)
          else
            notify.error("Failed to update frontmatter")
          end
        end)
      end)
    end)
  end

  run_builder()
  return true
end
