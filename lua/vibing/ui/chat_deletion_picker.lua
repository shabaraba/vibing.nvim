---@class Vibing.UI.ChatDeletionPicker
local M = {}

local notify = require("vibing.core.utils.notify")
local DeleteChatsUseCase = require("vibing.application.chat.use_cases.delete_chats")
local Frontmatter = require("vibing.infrastructure.storage.frontmatter")

---@param success boolean
---@param message string
local function notify_result(success, message)
  if success then
    notify.info(message)
  else
    notify.error(message)
  end
end

---@param save_dir string
---@param config table
---@param unrenamed_only boolean|nil
function M.show(save_dir, config, unrenamed_only)
  local has_telescope = pcall(require, "telescope")
  if not has_telescope then
    M._show_native(save_dir, config, unrenamed_only)
    return
  end

  M._show_telescope(save_dir, config, unrenamed_only)
end

---@param save_dir string
---@param config table
---@param unrenamed_only boolean|nil
function M._show_telescope(save_dir, config, unrenamed_only)
  local pickers = require("telescope.pickers")
  local finders = require("telescope.finders")
  local conf = require("telescope.config").values
  local actions = require("telescope.actions")
  local action_state = require("telescope.actions.state")
  local entry_display = require("telescope.pickers.entry_display")
  local FileEntity = require("vibing.domain.chat.file_entity")

  local find_command = { "fd", "--type", "f", "--extension", "md", ".", save_dir }
  if vim.fn.executable("fd") == 0 then
    find_command = { "find", save_dir, "-type", "f", "-name", "*.md" }
  end

  local displayer = entry_display.create({
    separator = " ",
    items = {
      { width = 50 }, -- ファイル名
      { width = 20 }, -- 作成日時
      { width = 10 }, -- サイズ
      { remaining = true }, -- パス
    },
  })

  local picker = pickers.new({}, {
    prompt_title = unrenamed_only and "Delete Unrenamed Chats (<Tab> to select, <CR> to delete)"
      or "Delete Chats (<Tab> to select, <CR> to delete)",
    finder = finders.new_oneshot_job(find_command, {
      entry_maker = function(line)
        -- フロントマターでvibing.nvimチャットファイルかどうかを判定
        if not Frontmatter.is_vibing_chat_file(line) then
          return nil
        end

        local entity = FileEntity.new(line)
        if not entity then
          return nil
        end

        if unrenamed_only and entity:is_renamed_file() then
          return nil
        end

        return {
          value = entity,
          display = function(entry)
            local e = entry.value
            return displayer({
              { e:get_display_name(), "TelescopeResultsIdentifier" },
              { e:get_formatted_date(), "TelescopeResultsNumber" },
              { e:get_formatted_size(), "TelescopeResultsString" },
              { e:get_relative_path(), "TelescopeResultsComment" },
            })
          end,
          ordinal = entity:get_display_name() .. " " .. entity:get_relative_path(),
        }
      end,
    }),
    sorter = conf.file_sorter({}),
    attach_mappings = function(prompt_bufnr, map)
      actions.select_default:replace(function()
        local picker_obj = action_state.get_current_picker(prompt_bufnr)
        local selections = picker_obj:get_multi_selection()

        if #selections == 0 then
          local current_entry = action_state.get_selected_entry()
          if current_entry then
            selections = { current_entry }
          end
        end

        actions.close(prompt_bufnr)

        if #selections == 0 then
          notify.warn("No files selected")
          return
        end

        local selected_entities = vim.tbl_map(function(s) return s.value end, selections)

        DeleteChatsUseCase.delete_selected(selected_entities, config, notify_result)
      end)

      return true
    end,
  })

  picker:find()
end

---@param save_dir string
---@param config table
---@param unrenamed_only boolean|nil
function M._show_native(save_dir, config, unrenamed_only)
  local entities = unrenamed_only and DeleteChatsUseCase.list_unrenamed_files(save_dir)
    or DeleteChatsUseCase.list_all_files(save_dir)

  if #entities == 0 then
    notify.info(unrenamed_only and "No unrenamed chat files found" or "No chat files found")
    return
  end

  vim.ui.select(entities, {
    prompt = unrenamed_only and "Select unrenamed chat to delete:" or "Select chat to delete:",
    format_item = function(entity)
      return string.format("%s - %s (%s)", entity:get_display_name(), entity:get_formatted_date(), entity:get_formatted_size())
    end,
  }, function(choice)
    if not choice then
      return
    end

    DeleteChatsUseCase.delete_selected({ choice }, config, notify_result)
  end)
end

return M
