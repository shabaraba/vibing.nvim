---@class Vibing.Application.Chat.Search.BackgroundAgent
---チャットバッファを持たないエージェントのターンを1回、裏で走らせる。
---
---スキルと同じく grep しては読み、外れたら言い換えて探し直す仕事なのでツールが要り、軽量呼び出しに
---はできない。承認プロンプトを出す先が無いので、`exclusive_tools` に渡したツールの外は vibing の
---フックが、`dontAsk` で CLI 側の関門が、どちらも尋ねずに拒否する。ツールを1つも渡さなければ
---軽量呼び出しになり、道具もプロジェクト設定も持たないターンで構造化出力だけを返させる。
---空のリストは「ツールを1つも許さない通常のターン」で、軽量呼び出しとは別物。
local M = {}

---進捗の1行に収める長さ。`gh` や `rg` のコマンドはそのままだと枠を押し広げる
local MAX_DETAIL_CHARS = 60

---`Grep(70332)` のような、チャットの実況と同じ形の1行。MCP ツールは接頭辞を落とす
---@param tool string
---@param input table
---@return string
function M.tool_label(tool, input)
  tool = tool:match("^mcp__.+__(.+)$") or tool
  local detail = input.command or input.pattern or input.query or input.file_path or input.session_id
  if type(detail) ~= "string" or detail == "" then
    return tool
  end
  detail = detail:gsub("%s+", " ")
  if vim.fn.strchars(detail) > MAX_DETAIL_CHARS then
    detail = vim.fn.strcharpart(detail, 0, MAX_DETAIL_CHARS - 1) .. "…"
  end
  return string.format("%s(%s)", tool, detail)
end

---複数行の値を1行に畳む。エージェントの答え（`chat_judgement.lua` / `session_answer.lua`）が
---ラベルや要約に使う、文字列以外やnilは空文字として扱う
---@param value any
---@return string
function M.one_line(value)
  return type(value) == "string" and (vim.trim(value):gsub("%s*\n%s*", " ")) or ""
end

---設定された言語の名前（"Japanese" 等）。未設定なら nil
---@return string?
function M.language_name()
  local language_utils = require("vibing.core.utils.language")
  local code = language_utils.get_language_code(require("vibing").get_config().chat.language, "chat")
  return code and language_utils.language_names[code]
end

---@param language string? 要約と分類名に使う言語（"Japanese" 等）
---@return string
function M.language_line(language)
  if not language then
    return "Write each summary and group label in the language of the query."
  end
  return string.format("Write each summary and group label in %s.", language)
end

M.last_json = require("vibing.application.chat.search.json_answer").last

---@param agent table Resolved helper selection
---@param cwd string
---@param tools string[]? このターンが使えるツールの全部。nil なら道具を持たない軽量呼び出しにする
---@param on_tool fun(label: string) ツール呼び出しのたびに呼ばれる（進捗表示用）
---@return Vibing.AdapterOpts
function M.opts(agent, cwd, tools, on_tool)
  if tools == nil then
    return { lightweight = true, _ai_purpose = "helpers", model = agent.model, effort = agent.effort, cwd = cwd }
  end
  return {
    _ai_purpose = "helpers",
    model = agent.model,
    effort = agent.effort,
    cwd = cwd,
    permission_mode = "dontAsk",
    permissions_allow = vim.deepcopy(tools),
    exclusive_tools = vim.deepcopy(tools),
    on_tool_use_full = function(tool, input)
      on_tool(M.tool_label(tool, input or {}))
    end,
  }
end

---ベースラインを取るのは「書きうるツール」が許可されたとき。`Bash(rg:*)` もそれに数えられる
---ので、チャットのターンが終わり際にやる片付けをここでも済ませる
---@param turn_id string?
local function release_turn(turn_id)
  if not turn_id then
    return
  end
  require("vibing.core.utils.git_snapshot").clear(turn_id)
  require("vibing.core.utils.request_diff").clear(turn_id)
  require("vibing.application.chat.worktree_binding").clear(turn_id)
end

---@param prompt string
---@param tools string[]? nil なら軽量呼び出し（`M.opts`）
---@param on_tool fun(label: string)
---@param callback fun(text: string?, error: string?)
---@param schema table? JSON Schema used when the backend supports structured output
---@param overrides Vibing.AdapterOpts? この呼び出しだけの上書き（`thinking = false` 等）
function M.run(prompt, tools, on_tool, callback, schema, overrides)
  local vibing = require("vibing")
  local adapter = vibing.get_helper_adapter()
  if not adapter then
    callback(nil, "No adapter configured")
    return
  end

  local collected = {}
  local turn_id
  local structured
  local opts = M.opts(
    require("vibing.core.utils.ai_config").resolve(vibing.get_config(), nil, true),
    vim.fn.getcwd(),
    tools,
    on_tool
  )
  opts = vim.tbl_extend("force", opts, overrides or {})
  local use_schema = schema and adapter.supports and adapter:supports("structured_output")
  if use_schema then
    opts.output_schema = schema
    opts.on_structured_output = function(value)
      structured = value
    end
    if adapter:supports("structured_output_file") then
      opts.output_schema_path = vim.fn.tempname() .. ".json"
      local ok, err = pcall(vim.fn.writefile, { vim.json.encode(schema) }, opts.output_schema_path)
      if not ok or err ~= 0 then
        vim.fn.delete(opts.output_schema_path)
        callback(nil, "Could not write the output schema: " .. tostring(err))
        return
      end
    end
    if adapter:supports("structured_output_tool") then
      if opts.exclusive_tools then
        opts.exclusive_tools[#opts.exclusive_tools + 1] = "StructuredOutput"
        opts.permissions_allow[#opts.permissions_allow + 1] = "StructuredOutput"
      end
      prompt = prompt .. "\nSubmit the final result with StructuredOutput instead of a JSON code block."
    else
      prompt = prompt
        .. "\nAn output schema is configured: return the final result in that schema, without Markdown fences."
    end
  end

  turn_id = adapter:stream(prompt, opts, function(chunk)
    collected[#collected + 1] = chunk
  end, function(response)
    if opts.output_schema_path then
      vim.fn.delete(opts.output_schema_path)
    end
    release_turn(turn_id)

    if response.error then
      callback(nil, response.error)
      return
    end

    if use_schema then
      if type(structured) ~= "table" then
        callback(nil, "the search agent returned no structured result")
      else
        callback(vim.json.encode(structured), nil)
      end
      return
    end

    local text = table.concat(collected)
    callback(text ~= "" and text or (response.content or ""), nil)
  end)
end

return M
