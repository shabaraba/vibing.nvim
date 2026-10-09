---@class Vibing.Application.Chat.Search.SessionPrompt
---`:VibingSessionSearch` のエージェントへの依頼。Claude/Codex の JSONL セッションログを
---`nvim_session_search` / `nvim_session_read` で探させ、結果を JSON で返させる。
local M = {}

local ChatPrompt = require("vibing.application.chat.search.chat_prompt")
local tools_constants = require("vibing.core.constants.tools")

---依頼文の書き出し。検索のターン自身もセッションログに残るので、これで始まるセッションは
---以前の検索として除外させる
M.OPENING = "Find the past Claude and Codex CLI sessions relevant to the query below."

---@param name string vibing-nvim の MCP ツール名（`nvim_` から）
---@return string[] 登録のされ方ごとの完全な名前
local function vibing_mcp_names(name)
  return vim.tbl_map(function(pattern)
    return pattern:gsub("%*$", "") .. name
  end, tools_constants.VIBING_NVIM_MCP_TOOL_PATTERNS)
end

---MCP ツールは遅延ロードされうるので、スキーマを引く `ToolSearch` も渡す
M.TOOLS = vim.iter({
  { "ToolSearch" },
  vibing_mcp_names("nvim_session_search"),
  vibing_mcp_names("nvim_session_read"),
}):flatten():totable()

---@param query string
---@param cwd string
---@param language string?
---@return string
function M.build(query, cwd, language)
  return table.concat({
    M.OPENING,
    "",
    "Query: " .. query,
    "Current working directory: " .. cwd,
    "",
    "Use the vibing-nvim MCP tools nvim_session_search and nvim_session_read (load them with",
    "ToolSearch if they are deferred). They read the CLI's own JSONL logs, including sessions",
    "started outside vibing.nvim.",
    "",
    "1. nvim_session_search is a literal, case-insensitive substring match. Turn the query into",
    "   2-4 short keywords, including rephrasings in both Japanese and English, and search each.",
    "   If nothing matches, rephrase and search again. Do not filter by working_dir unless the",
    "   query asks for one project.",
    "2. Read enough of each candidate with nvim_session_read to judge whether it is actually about",
    "   the query. Drop sessions that mention it only in passing. Never list a session just",
    "   because it is recent: an empty result is a valid answer.",
    '3. Skip every session whose first user message starts with "Find the past": those are',
    "   earlier searches like this one, including this session itself.",
    "4. Group the survivors by how they relate to the query. Use as few groups as fit.",
    "",
    ChatPrompt.language_line(language),
    "",
    "End your answer with exactly one JSON code block in this shape and nothing after it:",
    "```json",
    '{"groups": [{"label": "<group>", "sessions": [{"backend": "claude|codex", "session_id": "<id>",'
      .. ' "cwd": "<cwd>", "updated_at": "<updated_at>", "title": "<short topic>",'
      .. ' "summary": "<1-2 lines>"}]}]}',
    "```",
    "Copy backend, session_id, cwd and updated_at exactly as nvim_session_search reported them.",
    'Order groups from most to least relevant. If nothing is relevant, return {"groups": []}.',
  }, "\n")
end

return M
