local Context = require("vibing.context")
local OutputBuffer = require("vibing.ui.output_buffer")

---@class Vibing.InlineAction
local M = {}

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
---@param action_name? string
function M.execute(action_name)
  local vibing = require("vibing")
  local config = vibing.get_config()
  local adapter = vibing.get_adapter()

  if not adapter then
    vim.notify("[vibing] No adapter configured", vim.log.levels.ERROR)
    return
  end

  -- アクション名を決定
  action_name = action_name or config.inline.default_action
  if action_name == "" then
    action_name = config.inline.default_action
  end

  local action = M.actions[action_name]
  if not action then
    vim.notify(
      string.format("[vibing] Unknown action: %s", action_name),
      vim.log.levels.ERROR
    )
    return
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
---@param adapter Vibing.Adapter
---@param prompt string
---@param opts Vibing.AdapterOpts
---@param title string
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
---@param adapter Vibing.Adapter
---@param prompt string
---@param opts Vibing.AdapterOpts
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
---@param prompt string
---@param use_output boolean
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
