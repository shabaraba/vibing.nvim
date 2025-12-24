local Context = require("vibing.context")
local OutputBuffer = require("vibing.ui.output_buffer")
local notify = require("vibing.utils.notify")
local Language = require("vibing.utils.language")

---@class Vibing.ActionConfig
---@field prompt string アクションの基本プロンプト
---@field tools string[] 許可するツールリスト（Edit, Write等）
---@field use_output_buffer boolean 結果をフローティングウィンドウで表示するか

---@class Vibing.InlineAction
local M = {}

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

---インラインアクションを実行
---ビジュアル選択範囲に対して事前定義アクションまたはカスタムプロンプトを実行
---アクション名が未定義の場合は自然言語指示としてcustom()に委譲
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
      opts.permissions_allow = config.permissions.allow
    end
    if config.permissions.deny then
      opts.permissions_deny = config.permissions.deny
    end
  end

  if action.tools and #action.tools > 0 and adapter:supports("tools") then
    opts.tools = action.tools
  end

  if action.use_output_buffer then
    M._execute_with_output(adapter, prompt, opts, action_or_prompt)
  else
    -- Check if preview is enabled in config
    if config.preview and config.preview.enabled then
      M._execute_with_preview(adapter, prompt, opts, action_or_prompt, additional_instruction)
    else
      M._execute_direct(adapter, prompt, opts)
    end
  end
end

---出力バッファに結果を表示
---フローティングウィンドウで応答を表示（explainアクション等で使用）
---ストリーミング対応アダプターの場合はリアルタイム表示
---@param adapter Vibing.Adapter 使用するアダプター
---@param prompt string 実行するプロンプト（選択範囲のメンション含む）
---@param opts Vibing.AdapterOpts アダプターオプション
---@param title string ウィンドウタイトル（例: "Explain"）
function M._execute_with_output(adapter, prompt, opts, title)
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
      end)
    end)
  else
    local response = adapter:execute(prompt, opts)
    if response.error then
      output:show_error(response.error)
    else
      output:set_content(response.content)
    end
  end
end

---直接実行（コード変更）
---アダプターに直接実行させてコードを変更（fix, feat, refactor, test等で使用）
---進捗表示、結果表示、ファイル自動リロードを含む
---@param adapter Vibing.Adapter 使用するアダプター
---@param prompt string 実行するプロンプト（選択範囲のメンション含む）
---@param opts Vibing.AdapterOpts アダプターオプション（tools含む）
function M._execute_direct(adapter, prompt, opts)
  local BufferReload = require("vibing.utils.buffer_reload")
  local vibing = require("vibing")
  local config = vibing.get_config()

  -- StatusManager作成
  local StatusManager = require("vibing.status_manager")
  local status_mgr = StatusManager:new(config.status)

  local response_text = {}

  -- opts に action_type と status_manager を追加
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
          -- 変更されたファイルをリロード
          BufferReload.reload_files(modified_files)

          -- 結果を表示
          M._show_results(modified_files, table.concat(response_text, ""))
        end
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
  end
end

---プレビュー付きで実行（コード変更）
---アダプターに実行させてコードを変更し、完了後にプレビューUIを表示
---Git管理下のプロジェクトでのみ動作し、未管理の場合は_execute_directにフォールバック
---@param adapter Vibing.Adapter 使用するアダプター
---@param prompt string 実行するプロンプト（選択範囲のメンション含む）
---@param opts Vibing.AdapterOpts アダプターオプション（tools含む）
---@param action string アクション名（fix, feat等）
---@param instruction string|nil 追加指示
function M._execute_with_preview(adapter, prompt, opts, action, instruction)
  local Git = require("vibing.utils.git")

  -- Git管理下かチェック
  if not Git.is_git_repo() then
    notify.warn("Preview requires Git repository. Falling back to direct execution.", "Inline")
    return M._execute_direct(adapter, prompt, opts)
  end

  local BufferReload = require("vibing.utils.buffer_reload")
  local vibing = require("vibing")
  local config = vibing.get_config()

  -- 選択範囲のファイル内容を保存（Claude変更前の状態）
  local current_buf = vim.api.nvim_get_current_buf()
  local file_path = vim.api.nvim_buf_get_name(current_buf)
  local saved_contents = {}

  if file_path ~= "" then
    -- 絶対パスに正規化
    local normalized_path = vim.fn.fnamemodify(file_path, ":p")
    local content = vim.api.nvim_buf_get_lines(current_buf, 0, -1, false)
    saved_contents[normalized_path] = content
  end

  -- StatusManager作成
  local StatusManager = require("vibing.status_manager")
  local status_mgr = StatusManager:new(config.status)

  local response_text = {}

  -- opts に action_type と status_manager を追加
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
          -- 変更されたファイルをリロード
          BufferReload.reload_files(modified_files)

          -- セッションIDを取得
          local session_id = nil
          if adapter:supports("session") then
            session_id = adapter:get_session_id()
          end

          -- プレビューUIを起動
          local InlinePreview = require("vibing.ui.inline_preview")
          InlinePreview.setup("inline", modified_files, table.concat(response_text, ""), saved_contents, nil, prompt, action, instruction, session_id)
        end
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

      -- セッションIDを取得
      local session_id = nil
      if adapter:supports("session") then
        session_id = adapter:get_session_id()
      end

      -- プレビューUIを起動
      local InlinePreview = require("vibing.ui.inline_preview")
      InlinePreview.setup("inline", modified_files, response.content, saved_contents, nil, prompt, action, instruction, session_id)
    end
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
    table.insert(lines, "## Modified Files")
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

  -- 言語設定を適用
  local lang_code = Language.get_language_code(config.language, "inline")
  local final_prompt = Language.add_language_instruction(prompt, lang_code)

  -- プロンプトに@file:path:L10-L25形式のメンションを含める
  local full_prompt = final_prompt .. "\n\n" .. selection_context
  local opts = {}

  if use_output then
    M._execute_with_output(adapter, full_prompt, opts, "Result")
  else
    -- Check if preview is enabled in config
    if config.preview and config.preview.enabled then
      M._execute_with_preview(adapter, full_prompt, opts, "custom", prompt)
    else
      M._execute_direct(adapter, full_prompt, opts)
    end
  end
end

return M
