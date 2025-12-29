local Context = require("vibing.context")
local OutputBuffer = require("vibing.ui.output_buffer")
local notify = require("vibing.utils.notify")
local Language = require("vibing.utils.language")
local BufferIdentifier = require("vibing.utils.buffer_identifier")

---@class Vibing.ActionConfig
---@field prompt string アクションの基本プロンプト
---@field tools string[] 許可するツールリスト（Edit, Write等）
---@field use_output_buffer boolean 結果をフローティングウィンドウで表示するか

---@class Vibing.InlineAction
local M = {}

---@class Vibing.InlineQueue
---@field tasks table[] キューイングされたタスクのリスト
---@field is_executing boolean 実行中フラグ
local queue = {
  tasks = {},
  is_executing = false,
}

---事前定義されたインラインアクション設定
---fix, feat, explain, refactor, testの5種類を提供
---@type table<string, Vibing.ActionConfig>
M.actions = {
  fix = {
    prompt = "Fix the following code issues:",
    tools = { "Edit" },
    use_output_buffer = false,
  },
  feat = {
    prompt = "Make the requested changes to the selected code by writing actual code. You MUST use Edit or Write tools to modify or create files. Do not just explain or provide suggestions - write the implementation directly into the files:",
    tools = { "Edit", "Write" },
    use_output_buffer = false,
  },
  explain = {
    prompt = "Explain the following code:",
    tools = {},
    use_output_buffer = true,
  },
  refactor = {
    prompt = "Refactor the following code for better readability and maintainability:",
    tools = { "Edit" },
    use_output_buffer = false,
  },
  test = {
    prompt = "Generate tests for the following code:",
    tools = { "Edit", "Write" },
    use_output_buffer = false,
  },
}

---キューから次のタスクを取り出して実行
---タスクがない場合は何もしない
local function process_queue()
  if queue.is_executing or #queue.tasks == 0 then
    return
  end

  queue.is_executing = true
  local task = table.remove(queue.tasks, 1)

  -- キューの残りタスク数を通知
  if #queue.tasks > 0 then
    notify.info(string.format("Executing task (%d more in queue)...", #queue.tasks), "Inline")
  end

  -- on_completeコールバックを作成（エラー時も必ず呼ばれるようにする）
  local on_complete = function()
    queue.is_executing = false
    process_queue()
  end

  -- タスクを実行（pcallでラップしてエラー時もキューが進むようにする）
  local success, err = pcall(task.execute_fn, on_complete)
  if not success then
    -- エラー内容を表示してデバッグを支援
    local error_msg = "Task execution failed"
    if err and type(err) == "string" then
      error_msg = error_msg .. ": " .. err
    end
    notify.error(error_msg, "Inline")
    -- エラー時もon_completeを呼び出して次のタスクに進む
    on_complete()
  end
end

---タスクをキューに追加
---@param task table タスクオブジェクト { execute_fn: function }
local function enqueue_task(task)
  table.insert(queue.tasks, task)

  -- 通知
  if queue.is_executing then
    notify.info(string.format("Task queued (%d tasks waiting)", #queue.tasks), "Inline")
  end

  -- キュー処理を開始
  process_queue()
end

---Apply unsaved buffer handling to prompt and opts
---@param prompt string Original prompt
---@param opts table Options table (will be modified)
---@param is_modified boolean Whether buffer has unsaved changes
---@return string Modified prompt
local function apply_unsaved_buffer_handling(prompt, opts, is_modified)
  if not is_modified then
    return prompt
  end

  -- Modify prompt
  prompt = prompt
    .. "\n\nIMPORTANT: This buffer has unsaved changes. You MUST use mcp__vibing-nvim__nvim_set_buffer tool to edit the buffer directly, NOT the Edit or Write tools. This ensures the changes are applied to the current buffer state, not the saved file."

  -- Initialize permission lists if needed
  if not opts.permissions_allow then
    opts.permissions_allow = {}
  end
  if not opts.permissions_deny then
    opts.permissions_deny = {}
  end

  -- Remove Edit/Write from allow list to prevent conflicts
  opts.permissions_allow = vim.tbl_filter(function(tool)
    return tool ~= "Edit" and tool ~= "Write"
  end, opts.permissions_allow)

  -- Deny Edit/Write tools for unsaved buffers
  if not vim.tbl_contains(opts.permissions_deny, "Edit") then
    table.insert(opts.permissions_deny, "Edit")
  end
  if not vim.tbl_contains(opts.permissions_deny, "Write") then
    table.insert(opts.permissions_deny, "Write")
  end

  -- Ensure nvim_set_buffer is allowed
  if not vim.tbl_contains(opts.permissions_allow, "mcp__vibing-nvim__nvim_set_buffer") then
    table.insert(opts.permissions_allow, "mcp__vibing-nvim__nvim_set_buffer")
  end

  return prompt
end

---インラインアクションを実行
---ビジュアル選択範囲に対して事前定義アクションまたはカスタムプロンプトを実行
---アクション名が未定義の場合は自然言語指示としてcustom()に委譲
---タスクは自動的にキューに追加され、直列実行される
---@param action_or_prompt? string アクション名（fix, feat, explain, refactor, test）または自然言語指示
---@param additional_instruction? string 追加の指示（例: "日本語で", "using TypeScript"）
function M.execute(action_or_prompt, additional_instruction)
  local vibing = require("vibing")
  local config = vibing.get_config()
  local adapter = vibing.get_adapter()

  if not adapter then
    notify.error("No adapter configured", "Inline")
    return
  end

  -- アクション名が未指定の場合はエラー（通常はピッカーから必ず渡される）
  if not action_or_prompt or action_or_prompt == "" then
    notify.error("No action or prompt specified", "Inline")
    return
  end

  local action = M.actions[action_or_prompt]

  -- If not a predefined action, treat as custom natural language instruction
  if not action then
    return M.custom(action_or_prompt, false)
  end

  -- 選択範囲のコンテキストを取得
  local selection_context = Context.get_selection()
  if not selection_context then
    notify.warn("No selection", "Inline")
    return
  end

  -- Check if current buffer has unsaved changes
  local current_buf = vim.api.nvim_get_current_buf()
  local is_modified = vim.bo[current_buf].modified

  -- 言語設定を適用
  local lang_code = Language.get_language_code(config.language, "inline")
  local base_prompt = Language.add_language_instruction(action.prompt, lang_code)

  -- 追加指示がある場合はベースプロンプトに追加
  if additional_instruction and additional_instruction ~= "" then
    base_prompt = base_prompt .. " " .. additional_instruction
  end

  -- プロンプトに@file:path:L10-L25形式のメンションを含める
  local prompt = base_prompt .. "\n\n" .. selection_context

  local opts = {}

  -- Permissions設定を追加
  if config.permissions then
    if config.permissions.mode then
      opts.permission_mode = config.permissions.mode
    end
    if config.permissions.allow then
      opts.permissions_allow = vim.deepcopy(config.permissions.allow)
    end
    if config.permissions.deny then
      opts.permissions_deny = vim.deepcopy(config.permissions.deny)
    end
  end

  -- Apply unsaved buffer handling
  prompt = apply_unsaved_buffer_handling(prompt, opts, is_modified)

  if action.tools and #action.tools > 0 and adapter:supports("tools") then
    opts.tools = action.tools
  end

  -- タスクをキューに追加
  local task = {
    execute_fn = function(on_complete)
      if action.use_output_buffer then
        M._execute_with_output_queued(adapter, prompt, opts, action_or_prompt, on_complete)
      else
        -- Check if preview is enabled in config
        if config.preview and config.preview.enabled then
          M._execute_with_preview_queued(adapter, prompt, opts, action_or_prompt, additional_instruction, on_complete)
        else
          M._execute_direct_queued(adapter, prompt, opts, on_complete)
        end
      end
    end,
  }

  enqueue_task(task)
end

---出力バッファに結果を表示 - キュー対応版
---@param adapter Vibing.Adapter 使用するアダプター
---@param prompt string 実行するプロンプト
---@param opts Vibing.AdapterOpts アダプターオプション
---@param title string ウィンドウタイトル
---@param on_complete function 完了時のコールバック
function M._execute_with_output_queued(adapter, prompt, opts, title, on_complete)
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
function M._execute_direct_queued(adapter, prompt, opts, on_complete)
  local BufferReload = require("vibing.utils.buffer_reload")
  local vibing = require("vibing")
  local config = vibing.get_config()

  local StatusManager = require("vibing.status_manager")
  local status_mgr = StatusManager:new(config.status)

  local response_text = {}

  opts.action_type = "inline"
  opts.status_manager = status_mgr

  if adapter:supports("streaming") then
    opts.streaming = true
    adapter:stream(prompt, opts, function(chunk)
      table.insert(response_text, chunk)
    end, function(response)
      vim.schedule(function()
        local modified_files = status_mgr:get_modified_files()

        if response.error then
          status_mgr:set_error(response.error)
          notify.error(response.error, "Inline")
        else
          status_mgr:set_done(modified_files)
          BufferReload.reload_files(modified_files)
          M._show_results(modified_files, table.concat(response_text, ""))
        end

        -- タスク完了を通知
        on_complete()
      end)
    end)
  else
    local response = adapter:execute(prompt, opts)
    local modified_files = status_mgr:get_modified_files()

    if response.error then
      status_mgr:set_error(response.error)
      notify.error(response.error, "Inline")
    else
      status_mgr:set_done(modified_files)
      BufferReload.reload_files(modified_files)
      M._show_results(modified_files, response.content)
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
function M._execute_with_preview_queued(adapter, prompt, opts, action, instruction, on_complete)
  local Git = require("vibing.utils.git")

  if not Git.is_git_repo() then
    notify.warn("Preview requires Git repository. Falling back to direct execution.", "Inline")
    return M._execute_direct_queued(adapter, prompt, opts, on_complete)
  end

  local BufferReload = require("vibing.utils.buffer_reload")
  local vibing = require("vibing")
  local config = vibing.get_config()

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

  local StatusManager = require("vibing.status_manager")
  local status_mgr = StatusManager:new(config.status)
  local response_text = {}

  opts.action_type = "inline"
  opts.status_manager = status_mgr

  if adapter:supports("streaming") then
    opts.streaming = true
    adapter:stream(prompt, opts, function(chunk)
      table.insert(response_text, chunk)
    end, function(response)
      vim.schedule(function()
        local modified_files = status_mgr:get_modified_files()

        if response.error then
          status_mgr:set_error(response.error)
          notify.error(response.error, "Inline")
        else
          status_mgr:set_done(modified_files)
          BufferReload.reload_files(modified_files)

          local session_id = nil
          if adapter:supports("session") and response._handle_id then
            session_id = adapter:get_session_id(response._handle_id)
            -- セッションIDを取得したので、adapter からクリーンアップ
            adapter:cleanup_session(response._handle_id)
          end

          local InlinePreview = require("vibing.ui.inline_preview")
          InlinePreview.setup("inline", modified_files, table.concat(response_text, ""), saved_contents, nil, prompt, action, instruction, session_id)
        end

        -- タスク完了を通知
        on_complete()
      end)
    end)
  else
    local response = adapter:execute(prompt, opts)
    local modified_files = status_mgr:get_modified_files()

    if response.error then
      status_mgr:set_error(response.error)
      notify.error(response.error, "Inline")
    else
      status_mgr:set_done(modified_files)
      BufferReload.reload_files(modified_files)

      local session_id = nil
      if adapter:supports("session") and response._handle_id then
        session_id = adapter:get_session_id(response._handle_id)
        -- セッションIDを取得したので、adapter からクリーンアップ
        adapter:cleanup_session(response._handle_id)
      end

      local InlinePreview = require("vibing.ui.inline_preview")
      InlinePreview.setup("inline", modified_files, response.content, saved_contents, nil, prompt, action, instruction, session_id)
    end

    -- タスク完了を通知
    on_complete()
  end
end

---実行結果を表示
---変更されたファイル一覧とClaudeの応答をOutputBufferで表示
---@param modified_files string[] 変更されたファイルパスのリスト
---@param response_text string Claudeの応答テキスト
function M._show_results(modified_files, response_text)
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

---カスタムプロンプトでインライン実行
---事前定義アクション以外の自然言語指示を実行
---:VibingCustomコマンドやexecute()から未定義アクション名で呼び出される
---タスクは自動的にキューに追加され、直列実行される
---@param prompt string 自然言語指示（例: "Add error handling", "Optimize performance"）
---@param use_output boolean 結果をフローティングウィンドウで表示するか（false: コード直接変更）
function M.custom(prompt, use_output)
  local vibing = require("vibing")
  local config = vibing.get_config()
  local adapter = vibing.get_adapter()

  if not adapter then
    notify.error("No adapter configured", "Inline")
    return
  end

  local selection_context = Context.get_selection()
  if not selection_context then
    notify.warn("No selection", "Inline")
    return
  end

  -- Check if current buffer has unsaved changes
  local current_buf = vim.api.nvim_get_current_buf()
  local is_modified = vim.bo[current_buf].modified

  -- 言語設定を適用
  local lang_code = Language.get_language_code(config.language, "inline")
  local final_prompt = Language.add_language_instruction(prompt, lang_code)

  -- プロンプトに@file:path:L10-L25形式のメンションを含める
  local full_prompt = final_prompt .. "\n\n" .. selection_context

  local opts = {}

  -- Permissions設定を追加（configから）
  if config.permissions then
    if config.permissions.mode then
      opts.permission_mode = config.permissions.mode
    end
    if config.permissions.allow then
      opts.permissions_allow = vim.deepcopy(config.permissions.allow)
    end
    if config.permissions.deny then
      opts.permissions_deny = vim.deepcopy(config.permissions.deny)
    end
  end

  -- Apply unsaved buffer handling
  full_prompt = apply_unsaved_buffer_handling(full_prompt, opts, is_modified)

  -- タスクをキューに追加
  local task = {
    execute_fn = function(on_complete)
      if use_output then
        M._execute_with_output_queued(adapter, full_prompt, opts, "Result", on_complete)
      else
        -- Check if preview is enabled in config
        if config.preview and config.preview.enabled then
          M._execute_with_preview_queued(adapter, full_prompt, opts, "custom", prompt, on_complete)
        else
          M._execute_direct_queued(adapter, full_prompt, opts, on_complete)
        end
      end
    end,
  }

  enqueue_task(task)
end

return M
