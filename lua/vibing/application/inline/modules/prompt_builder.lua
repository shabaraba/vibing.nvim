---プロンプト構築モジュール
---選択範囲とプロンプトの統合、オプション設定

local Context = require("vibing.application.context.manager")
local Language = require("vibing.core.utils.language")
local UnsavedBuffer = require("vibing.application.inline.modules.unsaved_buffer")

---@class Vibing.PromptBuilderModule
local M = {}

---プロンプトとオプションを構築
---@param base_prompt string ベースプロンプト
---@param additional_instruction? string 追加指示
---@param config table vibing設定
---@param action_tools? string[] アクションで許可されるツール
---@return string|nil prompt 構築されたプロンプト（選択範囲がない場合はnil）
---@return table|nil opts アダプターオプション（選択範囲がない場合はnil）
function M.build(base_prompt, additional_instruction, config, action_tools)
  -- 選択範囲のコンテキストを取得
  local selection_context = Context.get_selection()
  if not selection_context then
    return nil, nil
  end

  -- ベースプロンプトを構築
  local prompt = base_prompt

  -- 追加指示がある場合はベースプロンプトに追加
  if additional_instruction and additional_instruction ~= "" then
    prompt = prompt .. " " .. additional_instruction
  end

  -- プロンプトに@file:path:L10-L25形式のメンションを含める
  prompt = prompt .. "\n\n" .. selection_context

  -- 言語設定を取得
  local lang_code = Language.get_language_code(config.language, "inline")

  local opts = {
    language = lang_code,
  }

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

  -- 未保存バッファのハンドリングを適用
  local is_modified = UnsavedBuffer.is_modified()
  -- Ensure is_modified is a boolean value
  if is_modified == nil then
    is_modified = false
  end
  prompt = UnsavedBuffer.apply_handling(prompt, opts, is_modified)

  -- ツール設定を追加
  local vibing = require("vibing")
  local adapter = vibing.get_adapter()
  if action_tools and #action_tools > 0 and adapter and adapter:supports("tools") then
    opts.tools = action_tools
  end

  return prompt, opts
end

return M
