---@class Vibing.Application.Chat.Search.BackgroundAgent
---チャットバッファを持たないエージェントのターンを1回、裏で走らせる。
---
---スキルと同じく grep しては読み、外れたら言い換えて探し直す仕事なのでツールが要り、軽量呼び出しに
---はできない。承認プロンプトを出す先が無いので、`exclusive_tools` に渡したツールの外は vibing の
---フックが、`dontAsk` で CLI 側の関門が、どちらも尋ねずに拒否する。
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

---設定された言語の名前（"Japanese" 等）。未設定なら nil
---@return string?
function M.language_name()
  local language_utils = require("vibing.core.utils.language")
  local code = language_utils.get_language_code(require("vibing").get_config().language, "chat")
  return code and language_utils.language_names[code]
end

---応答の末尾の JSON ブロックを読む。本文の途中にも例が出うるので、最後のブロックを採る
---@param text string?
---@return table? decoded
---@return string? error
function M.last_json(text)
  local block
  for found in (text or ""):gmatch("```json%s*\n(.-)\n%s*```") do
    block = found
  end
  block = block or (text or ""):match("(%b{})%s*$")
  if not block then
    return nil, "the search agent returned no JSON result"
  end

  local ok, decoded = pcall(vim.json.decode, block)
  if not ok or type(decoded) ~= "table" then
    return nil, "the search agent returned a malformed result"
  end
  return decoded, nil
end

---@param agent table `config.agent`
---@param cwd string
---@param tools string[] このターンが使えるツールの全部
---@param on_tool fun(label: string) ツール呼び出しのたびに呼ばれる（進捗表示用）
---@return Vibing.AdapterOpts
function M.opts(agent, cwd, tools, on_tool)
  return {
    model = agent.utility_model,
    effort = agent.utility_effort,
    cwd = cwd,
    permission_mode = "dontAsk",
    permissions_allow = vim.deepcopy(tools),
    exclusive_tools = vim.deepcopy(tools),    on_tool_use_full = function(tool, input)
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
---@param tools string[]
---@param on_tool fun(label: string)
---@param callback fun(text: string?, error: string?)
function M.run(prompt, tools, on_tool, callback)
  local vibing = require("vibing")
  local adapter = vibing.get_adapter()
  if not adapter then
    callback(nil, "No adapter configured")
    return
  end

  local collected = {}
  local turn_id

  turn_id = adapter:stream(
    prompt,
    M.opts(vibing.get_config().agent or {}, vim.fn.getcwd(), tools, on_tool),
    function(chunk)
      collected[#collected + 1] = chunk
    end,
    function(response)
      release_turn(turn_id)

      if response.error then
        callback(nil, response.error)
        return
      end

      local text = table.concat(collected)
      callback(text ~= "" and text or (response.content or ""), nil)
    end
  )
end

return M
