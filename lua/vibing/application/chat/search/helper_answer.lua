---@class Vibing.Application.Chat.Search.HelperAnswer
---ヘルパーモデルに、道具もプロジェクト設定も持たない軽量呼び出しで答えを1つ返させる。
---構造化出力に対応するバックエンドではその値を、対応しないものでは応答末尾の JSON を読む。
local M = {}

local JsonAnswer = require("vibing.application.chat.search.json_answer")

---@class Vibing.Chat.Search.HelperCall
---@field thinking false? この呼び出しだけ拡張思考を使わせない（`Vibing.AdapterOpts.thinking`）

---@param adapter Vibing.Adapter
---@param opts Vibing.AdapterOpts
---@param schema table
---@param prompt string
---@return string? prompt
---@return string? error
local function request_schema(adapter, opts, schema, prompt)
  opts.output_schema = schema
  if adapter:supports("structured_output_file") then
    opts.output_schema_path = vim.fn.tempname() .. ".json"
    local ok, err = pcall(vim.fn.writefile, { vim.json.encode(schema) }, opts.output_schema_path)
    if not ok or err ~= 0 then
      vim.fn.delete(opts.output_schema_path)
      return nil, "Could not write the output schema: " .. tostring(err)
    end
  end
  if adapter:supports("structured_output_tool") then
    return prompt .. "\nSubmit the final result with StructuredOutput instead of a JSON code block."
  end
  return prompt .. "\nAn output schema is configured: return the final result in that schema, without Markdown fences."
end

---@param prompt string
---@param schema table JSON Schema of the answer
---@param callback fun(value: table?, error: string?)
---@param call Vibing.Chat.Search.HelperCall?
function M.ask(prompt, schema, callback, call)
  local vibing = require("vibing")
  local adapter = vibing.get_helper_adapter()
  if not adapter then
    callback(nil, "No adapter configured")
    return
  end

  local agent = require("vibing.core.utils.ai_config").resolve(vibing.get_config(), nil, true)
  ---@type Vibing.AdapterOpts
  local opts = {
    lightweight = true,
    _ai_purpose = "helpers",
    model = agent.model,
    effort = agent.effort,
    cwd = vim.fn.getcwd(),
    thinking = call and call.thinking,
  }
  local structured
  local use_schema = adapter.supports and adapter:supports("structured_output")
  if use_schema then
    local schema_error
    prompt, schema_error = request_schema(adapter, opts, schema, prompt)
    if not prompt then
      callback(nil, schema_error)
      return
    end
    opts.on_structured_output = function(value)
      structured = value
    end
  end

  local collected = {}
  adapter:stream(prompt, opts, function(chunk)
    collected[#collected + 1] = chunk
  end, function(response)
    if opts.output_schema_path then
      vim.fn.delete(opts.output_schema_path)
    end
    if response.error then
      callback(nil, response.error)
    elseif not use_schema then
      local text = table.concat(collected)
      callback(JsonAnswer.last(text ~= "" and text or response.content))
    elseif type(structured) ~= "table" then
      callback(nil, "the search agent returned no structured result")
    else
      callback(structured)
    end
  end)
end

return M
