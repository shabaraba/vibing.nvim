---インラインアクション実行のユースケース
---事前定義アクションとカスタムプロンプトの実行を統合管理

local notify = require("vibing.core.utils.notify")
local ActionConfig = require("vibing.application.inline.modules.action_config")
local PromptBuilder = require("vibing.application.inline.modules.prompt_builder")
local TaskQueue = require("vibing.application.inline.modules.task_queue")
local Execution = require("vibing.application.inline.modules.execution")

---@class Vibing.InlineAction
local M = {}

-- Export action configurations for backward compatibility
M.actions = ActionConfig.actions

---インラインアクションを実行
---ビジュアル選択範囲に対して事前定義アクションまたはカスタムプロンプトを実行
---アクション名が未定義の場合は自然言語指示としてcustom()に委譲
---タスクは自動的にキューに追加され、直列実行される
---@param action_or_prompt? string アクション名（fix, feat, explain, refactor, test）または自然言語指示
---@param additional_instruction? string 追加の指示（例: "日本語で", "using TypeScript"）
function M.execute(action_or_prompt, additional_instruction)
  local vibing = require("vibing")
  local config = vibing.get_config()

  -- アクション名が未指定の場合はエラー（通常はピッカーから必ず渡される）
  if not action_or_prompt or action_or_prompt == "" then
    notify.error("No action or prompt specified", "Inline")
    return
  end

  local action = ActionConfig.get(action_or_prompt)

  -- アダプター選択: explainアクションでOllama有効ならOllama、それ以外はagent_sdk
  local adapter
  if action and action_or_prompt == "explain" and config.ollama and config.ollama.enabled then
    adapter = vibing.get_ollama_adapter()
    if not adapter then
      notify.warn("Ollama adapter not available, falling back to agent_sdk", "Inline")
      adapter = vibing.get_adapter()
    end
  else
    adapter = vibing.get_adapter()
  end

  if not adapter then
    notify.error("No adapter configured", "Inline")
    return
  end

  -- If not a predefined action, treat as custom natural language instruction
  if not action then
    return M.custom(action_or_prompt, false)
  end

  -- プロンプトとオプションを構築
  local prompt, opts = PromptBuilder.build(
    action.prompt,
    additional_instruction,
    config,
    action.tools
  )

  if not prompt or not opts then
    notify.warn("No selection", "Inline")
    return
  end

  -- タスクを作成してキューに追加
  local task_id = TaskQueue.generate_id(action_or_prompt)
  local task = TaskQueue.create_task(task_id, function(done)
    if action.use_output_buffer then
      Execution.execute_with_output(adapter, prompt, opts, action_or_prompt, done)
    else
      -- Check if preview is enabled in config
      if config.preview and config.preview.enabled then
        Execution.execute_with_preview(adapter, prompt, opts, action_or_prompt, additional_instruction, done)
      else
        Execution.execute_direct(adapter, prompt, opts, done)
      end
    end
  end)

  TaskQueue.enqueue(task)
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

  -- プロンプトとオプションを構築
  local full_prompt, opts = PromptBuilder.build(
    prompt,
    nil,  -- No additional instruction for custom prompts
    config,
    nil   -- No predefined tools for custom prompts
  )

  if not full_prompt or not opts then
    notify.warn("No selection", "Inline")
    return
  end

  -- タスクを作成してキューに追加
  local task_id = TaskQueue.generate_id("custom")
  local task = TaskQueue.create_task(task_id, function(done)
    if use_output then
      Execution.execute_with_output(adapter, full_prompt, opts, "Result", done)
    else
      -- Check if preview is enabled in config
      if config.preview and config.preview.enabled then
        Execution.execute_with_preview(adapter, full_prompt, opts, "custom", prompt, done)
      else
        Execution.execute_direct(adapter, full_prompt, opts, done)
      end
    end
  end)

  TaskQueue.enqueue(task)
end

-- Export internal functions for backward compatibility
M._execute_with_output_queued = Execution.execute_with_output
M._execute_direct_queued = Execution.execute_direct
M._execute_with_preview_queued = Execution.execute_with_preview
M._show_results = Execution.show_results

return M
