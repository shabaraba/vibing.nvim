---@class Vibing.Application.InlineExecutor
---インラインアクション実行ユースケース
local M = {}

local notify = require("vibing.core.utils.notify")
local QueueManager = require("vibing.application.inline.queue_manager")
local StatusManager = require("vibing.status_manager")
local BufferReload = require("vibing.core.utils.buffer_reload")
local language_utils = require("vibing.core.utils.language")

---インラインアクションを実行
---@param action table アクション定義
---@param context string コンテキスト
---@param additional_prompt string? 追加プロンプト
---@param adapter table アダプター
---@param config table 設定
---@param ui_callbacks table UIコールバック
function M.execute(action, context, additional_prompt, adapter, config, ui_callbacks)
  if not adapter then
    notify.error("No adapter configured", "Inline")
    return
  end

  local task = {
    id = string.format("%d_%d", vim.uv.hrtime(), math.random(1000, 9999)),
    execute = function(done)
      M._run_action(action, context, additional_prompt, adapter, config, ui_callbacks, done)
    end,
    cancel = function()
      adapter:cancel()
    end,
  }

  local pos = QueueManager.enqueue(task)
  if QueueManager.is_processing() and pos > 1 then
    notify.info(string.format("Task queued (%d tasks waiting)", pos - 1), "Inline")
  end

  QueueManager.process()
end

---アクションを実行
function M._run_action(action, context, additional_prompt, adapter, config, ui, done)
  local language = language_utils.get_language_for_action("inline", config.language)
  local language_instruction = language_utils.get_prompt_instruction(language)

  local prompt_parts = {
    action.prompt,
    "",
    context,
  }

  if additional_prompt and additional_prompt ~= "" then
    table.insert(prompt_parts, "")
    table.insert(prompt_parts, "Additional instructions: " .. additional_prompt)
  end

  if language_instruction and language_instruction ~= "" then
    table.insert(prompt_parts, "")
    table.insert(prompt_parts, language_instruction)
  end

  local prompt = table.concat(prompt_parts, "\n")

  local status_mgr = StatusManager:new(config.status)
  local modified_files = {}
  local file_tools = { Edit = true, Write = true, nvim_set_buffer = true }

  local opts = {
    streaming = true,
    action_type = "inline",
    status_manager = status_mgr,
    tools = action.tools,
    permissions_allow = action.tools,
    on_tool_use = function(tool, file_path)
      if file_tools[tool] and file_path and not vim.tbl_contains(modified_files, file_path) then
        table.insert(modified_files, file_path)
      end
    end,
  }

  if action.use_output_buffer and ui.create_output_buffer then
    local output_buf = ui.create_output_buffer(action.name)
    M._stream_to_buffer(adapter, prompt, opts, output_buf, status_mgr, modified_files, config, done)
  else
    if ui.show_progress then
      ui.show_progress(action.name)
    end
    M._stream_inline(adapter, prompt, opts, status_mgr, modified_files, config, ui, done)
  end
end

---出力バッファにストリーム
function M._stream_to_buffer(adapter, prompt, opts, output_buf, status_mgr, modified_files, config, done)
  adapter:stream(prompt, opts, function(chunk)
    vim.schedule(function()
      output_buf:append(chunk)
    end)
  end, function(response)
    vim.schedule(function()
      if response.error then
        status_mgr:set_error(response.error)
        output_buf:append("\n\n**Error:** " .. response.error)
      else
        status_mgr:set_done(modified_files)
      end

      if #modified_files > 0 then
        BufferReload.reload_files(modified_files)
      end

      done()
    end)
  end)
end

---インライン実行（プログレス表示）
function M._stream_inline(adapter, prompt, opts, status_mgr, modified_files, config, ui, done)
  adapter:stream(prompt, opts, function(_) end, function(response)
    vim.schedule(function()
      if ui.hide_progress then
        ui.hide_progress()
      end

      if response.error then
        status_mgr:set_error(response.error)
        notify.error(response.error, "Inline")
      else
        status_mgr:set_done(modified_files)
        if #modified_files > 0 then
          BufferReload.reload_files(modified_files)
          notify.info(string.format("Modified %d file(s)", #modified_files), "Inline")
        end
      end

      done()
    end)
  end)
end

return M
