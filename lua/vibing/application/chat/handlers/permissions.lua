local notify = require("vibing.core.utils.notify")
local permission_builder = require("vibing.ui.permission_builder")

---@param args string[]
---@param chat_buffer Vibing.ChatBuffer
---@return boolean
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

      -- Read back the current state so the allow/ask/deny prompt can show what is already set for
      -- this tool, instead of asking blind.
      local current_lists = {
        allow = chat_buffer:get_frontmatter_list("permissions_allow"),
        ask = chat_buffer:get_frontmatter_list("permissions_ask"),
        deny = chat_buffer:get_frontmatter_list("permissions_deny"),
      }

      permission_builder.prompt_permission_type(tool.name, current_lists, function(permission_type)
        if not permission_type then
          return
        end

        permission_builder.handle_pattern_selection(tool, permission_type, function(permission_string)
          if not permission_string then
            return
          end

          local key = permission_type == "allow" and "permissions_allow"
                   or permission_type == "ask" and "permissions_ask"
                   or "permissions_deny"
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
