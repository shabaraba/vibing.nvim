local Context = require("vibing.context")
local OutputBuffer = require("vibing.ui.output_buffer")

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
    prompt = "Implement the following feature:",
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
function M.execute(action_or_prompt)
  local vibing = require("vibing")
  local config = vibing.get_config()
  local adapter = vibing.get_adapter()

  if not adapter then
    vim.notify("[vibing] No adapter configured", vim.log.levels.ERROR)
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
    vim.notify("[vibing] No selection", vim.log.levels.WARN)
    return
  end

  -- プロンプトに@file:path:L10-L25形式のメンションを含める
  local prompt = action.prompt .. "\n\n" .. selection_context

  local opts = {}

  if action.tools and #action.tools > 0 and adapter:supports("tools") then
    opts.tools = action.tools
  end

  if action.use_output_buffer then
    M._execute_with_output(adapter, prompt, opts, action_name)
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
---結果は通知のみで、実際のコード変更はアダプターのツール実行で行われる
---@param adapter Vibing.Adapter 使用するアダプター
---@param prompt string 実行するプロンプト（選択範囲のメンション含む）
---@param opts Vibing.AdapterOpts アダプターオプション（tools含む）
function M._execute_direct(adapter, prompt, opts)
  vim.notify("[vibing] Executing...", vim.log.levels.INFO)

  if adapter:supports("streaming") then
    opts.streaming = true
    adapter:stream(prompt, opts, function(_)
      -- 進捗表示（オプション）
    end, function(response)
      vim.schedule(function()
        if response.error then
          vim.notify("[vibing] Error: " .. response.error, vim.log.levels.ERROR)
        else
          vim.notify("[vibing] Done", vim.log.levels.INFO)
        end
      end)
    end)
  else
    local response = adapter:execute(prompt, opts)
    if response.error then
      vim.notify("[vibing] Error: " .. response.error, vim.log.levels.ERROR)
    else
      vim.notify("[vibing] Done", vim.log.levels.INFO)
    end
  end
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
    vim.notify("[vibing] No adapter configured", vim.log.levels.ERROR)
    return
  end

  local selection_context = Context.get_selection()
  if not selection_context then
    vim.notify("[vibing] No selection", vim.log.levels.WARN)
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
