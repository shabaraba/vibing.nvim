---実行モジュール
---アダプターを使用した実際の実行ロジック（直接実行、出力バッファ、プレビュー）

local OutputBuffer = require("vibing.ui.output_buffer")
local notify = require("vibing.core.utils.notify")
local BufferIdentifier = require("vibing.core.utils.buffer_identifier")

---@class Vibing.ExecutionModule
local M = {}

---出力バッファに結果を表示 - キュー対応版
---@param adapter Vibing.Adapter 使用するアダプター
---@param prompt string 実行するプロンプト
---@param opts Vibing.AdapterOpts アダプターオプション
---@param title string ウィンドウタイトル
---@param on_complete function 完了時のコールバック
function M.execute_with_output(adapter, prompt, opts, title, on_complete)
  local output = OutputBuffer:new()
  output:open(title:sub(1, 1):upper() .. title:sub(2))

  local first_chunk = true

  if adapter:supports("streaming") then
    opts.streaming = true
    adapter:stream(prompt, opts, function(chunk)
      vim.schedule(function()
        output:append_chunk(chunk, first_chunk)
        first_chunk = false
      end)
    end, function(response)
      vim.schedule(function()
        if response.error then
          output:show_error(response.error)
        end
        -- タスク完了を通知
        on_complete()
      end)
    end)
  else
    local response = adapter:execute(prompt, opts)
    if response.error then
      output:show_error(response.error)
    else
      output:set_content(response.content)
    end
    -- タスク完了を通知
    on_complete()
  end
end

---直接実行（コード変更）- キュー対応版
---@param adapter Vibing.Adapter 使用するアダプター
---@param prompt string 実行するプロンプト
---@param opts Vibing.AdapterOpts アダプターオプション
---@param on_complete function 完了時のコールバック
function M.execute_direct(adapter, prompt, opts, on_complete)
  local response_text = {}

  opts.action_type = "inline"

  if adapter:supports("streaming") then
    opts.streaming = true
    adapter:stream(prompt, opts, function(chunk)
      table.insert(response_text, chunk)
    end, function(response)
      vim.schedule(function()
        if response.error then
          notify.error(response.error, "Inline")
        else
          M.show_results({}, table.concat(response_text, ""))
        end

        -- タスク完了を通知
        on_complete()
      end)
    end)
  else
    local response = adapter:execute(prompt, opts)

    if response.error then
      notify.error(response.error, "Inline")
    else
      M.show_results({}, response.content)
    end

    -- タスク完了を通知
    on_complete()
  end
end

---プレビュー付きで実行（コード変更）- キュー対応版
---@param adapter Vibing.Adapter 使用するアダプター
---@param prompt string 実行するプロンプト
---@param opts Vibing.AdapterOpts アダプターオプション
---@param action string アクション名
---@param instruction string|nil 追加指示
---@param on_complete function 完了時のコールバック
function M.execute_with_preview(adapter, prompt, opts, action, instruction, on_complete)
  local Git = require("vibing.core.utils.git")

  if not Git.is_git_repo() then
    notify.warn("Preview requires Git repository. Falling back to direct execution.", "Inline")
    return M.execute_direct(adapter, prompt, opts, on_complete)
  end

  local current_buf = vim.api.nvim_get_current_buf()
  local file_path = vim.api.nvim_buf_get_name(current_buf)
  local saved_contents = {}

  local content = vim.api.nvim_buf_get_lines(current_buf, 0, -1, false)
  if file_path ~= "" then
    local normalized_path = vim.fn.fnamemodify(file_path, ":p")
    saved_contents[normalized_path] = content
  else
    local buffer_id = BufferIdentifier.create_identifier(current_buf)
    saved_contents[buffer_id] = content
  end

  local response_text = {}

  opts.action_type = "inline"

  if adapter:supports("streaming") then
    opts.streaming = true
    adapter:stream(prompt, opts, function(chunk)
      table.insert(response_text, chunk)
    end, function(response)
      vim.schedule(function()
        if response.error then
          notify.error(response.error, "Inline")
        else
          local session_id = nil
          if adapter:supports("session") and response._handle_id then
            session_id = adapter:get_session_id(response._handle_id)
            -- セッションIDを取得したので、adapter からクリーンアップ
            adapter:cleanup_session(response._handle_id)
          end

          local InlinePreview = require("vibing.ui.inline_preview")
          InlinePreview.setup("inline", {}, table.concat(response_text, ""), saved_contents, nil, prompt, action, instruction, session_id)
        end

        -- タスク完了を通知
        on_complete()
      end)
    end)
  else
    local response = adapter:execute(prompt, opts)

    if response.error then
      notify.error(response.error, "Inline")
    else
      local session_id = nil
      if adapter:supports("session") and response._handle_id then
        session_id = adapter:get_session_id(response._handle_id)
        -- セッションIDを取得したので、adapter からクリーンアップ
        adapter:cleanup_session(response._handle_id)
      end

      local InlinePreview = require("vibing.ui.inline_preview")
      InlinePreview.setup("inline", {}, response.content, saved_contents, nil, prompt, action, instruction, session_id)
    end

    -- タスク完了を通知
    on_complete()
  end
end

---実行結果を表示
---変更されたファイル一覧とClaudeの応答をOutputBufferで表示
---@param modified_files string[] 変更されたファイルパスのリスト
---@param response_text string Claudeの応答テキスト
function M.show_results(modified_files, response_text)
  if #modified_files == 0 and (not response_text or response_text == "") then
    notify.info("Done (no changes)", "Inline")
    return
  end

  local output = OutputBuffer:new()
  local lines = {}

  if #modified_files > 0 then
    table.insert(lines, "### Modified Files")
    table.insert(lines, "")
    for _, f in ipairs(modified_files) do
      table.insert(lines, "- " .. f)
    end
    table.insert(lines, "")
  end

  if response_text and response_text ~= "" then
    table.insert(lines, "## Response")
    table.insert(lines, "")
    table.insert(lines, response_text)
  end

  output:open("Result")
  output:set_content(table.concat(lines, "\n"))
end

return M
