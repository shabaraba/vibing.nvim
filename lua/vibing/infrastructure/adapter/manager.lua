---@class Vibing.AdapterManager
---@field agent_sdk_adapter Vibing.Adapter
---@field ollama_adapter Vibing.Adapter?
---@field config Vibing.Config
local M = {}

---AdapterManagerのコンストラクタ
---@param config Vibing.Config 設定オブジェクト
---@param agent_sdk_adapter Vibing.Adapter デフォルトのアダプター（agent_sdk）
---@param ollama_adapter Vibing.Adapter? Ollamaアダプター（有効な場合）
---@return Vibing.AdapterManager
function M.new(config, agent_sdk_adapter, ollama_adapter)
  return setmetatable({
    config = config,
    agent_sdk_adapter = agent_sdk_adapter,
    ollama_adapter = ollama_adapter,
  }, { __index = M })
end

---ユースケースに応じた適切なアダプターを取得
---Ollama設定に基づいて、Ollamaまたはagent_sdkアダプターを返す
---@param use_case "doc"|"title"|nil ユースケース（"doc": ドキュメント生成, "title": タイトル生成, nil: デフォルト）
---@return Vibing.Adapter アダプターインスタンス
function M:get_adapter_for(use_case)
  -- Ollama使用判定
  local should_use_ollama = false
  if self.config.ollama and self.config.ollama.enabled and self.ollama_adapter then
    if use_case == "doc" and self.config.ollama.use_for_doc then
      should_use_ollama = true
    elseif use_case == "title" and self.config.ollama.use_for_title then
      should_use_ollama = true
    end
  end

  if should_use_ollama then
    return self.ollama_adapter
  end

  return self.agent_sdk_adapter
end

---デフォルトのアダプターを取得（agent_sdk）
---後方互換性のために提供
---@return Vibing.Adapter
function M:get_default_adapter()
  return self.agent_sdk_adapter
end

---Ollamaアダプターを取得
---後方互換性のために提供
---@return Vibing.Adapter?
function M:get_ollama_adapter()
  return self.ollama_adapter
end

return M
