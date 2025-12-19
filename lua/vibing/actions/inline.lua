local Context = require("vibing.context")
local OutputBuffer = require("vibing.ui.output_buffer")
local notify = require("vibing.utils.notify")

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
    prompt = "Implement the following feature by writing actual code. You MUST use Edit or Write tools to modify or create files. Do not just explain or provide suggestions - write the implementation directly into the files:",
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

  -- アクション名を決定
  action_or_prompt = action_or_prompt or config.inline.default_action
  if action_or_prompt == "" then
    action_or_prompt = config.inline.default_action
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

  -- 追加指示がある場合はベースプロンプトに追加
  local base_prompt = action.prompt
  if additional_instruction and additional_instruction ~= "" then
    base_prompt = base_prompt .. " " .. additional_instruction
  end

  -- プロンプトに@file:path:L10-L25形式のメンションを含める
  local prompt = base_prompt .. "\n\n" .. selection_context

  local opts = {}

  if action.tools and #action.tools > 0 and adapter:supports("tools") then
    opts.tools = action.tools
  end

  if action.use_output_buffer then
    M._execute_with_output(adapter, prompt, opts, action_or_prompt)
  else
    M._execute_direct(adapter, prompt, opts)
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
  local InlineProgress = require("vibing.ui.inline_progress")
  local BufferReload = require("vibing.utils.buffer_reload")

  local progress = InlineProgress:new()
  local ok, err = pcall(function()
    progress:show("Inline")
    progress:update_status("Starting...")
  end)
  if not ok then
    notify.warn("Progress UI unavailable: " .. tostring(err), "Inline")
  end

  local response_text = {}

  -- ツール使用時のコールバックを設定
  opts.on_tool_use = function(tool, file_path)
    vim.schedule(function()
      progress:update_tool(tool, file_path)
      progress:add_modified_file(file_path)
    end)
  end

  if adapter:supports("streaming") then
    opts.streaming = true
    adapter:stream(prompt, opts, function(chunk)
      table.insert(response_text, chunk)
    end, function(response)
      vim.schedule(function()
        local modified_files = progress:get_modified_files()
        progress:close()

        if response.error then
          notify.error(response.error, "Inline")
        else
          -- 変更されたファイルをリロード
          BufferReload.reload_files(modified_files)

          -- 結果を表示
          M._show_results(modified_files, table.concat(response_text, ""))
        end
      end)
    end)
  else
    local response = adapter:execute(prompt, opts)
    local modified_files = progress:get_modified_files()
    progress:close()

    if response.error then
      notify.error(response.error, "Inline")
    else
      BufferReload.reload_files(modified_files)
      M._show_results(modified_files, response.content)
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

  -- プロンプトに@file:path:L10-L25形式のメンションを含める
  local full_prompt = prompt .. "\n\n" .. selection_context
  local opts = {}

  if use_output then
    M._execute_with_output(adapter, full_prompt, opts, "Result")
  else
    M._execute_direct(adapter, full_prompt, opts)
  end
end

return M
