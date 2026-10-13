---@class Vibing.Application.Chat.Search.ChatPrompt
---`:VibingChatSearch` のエージェントへの依頼。手順は `vibing-chat-search` スキルと同じで、結果を
---本文ではなく JSON で返させるところだけが違う。
local M = {}

---読み取りしかしないツールだけ。`gh` は PR/issue の URL や番号からタイトルを引いてキーワードを
---作り直すためで、それ以外のサブコマンドは通さない。Grep / Glob は渡さない: `.vibing/` は
---`.gitignore` されていることが多く、ignore を尊重する両者はチャットを1件も見つけられない
M.TOOLS = {
  "Read",
  "Bash(rg:*)",
  "Bash(gh pr view:*)",
  "Bash(gh issue view:*)",
}

---@param language string? 要約と分類名に使う言語（"Japanese" 等）
---@return string
local function language_line(language)
  if not language then
    return "Write each summary and group label in the language of the query."
  end
  return string.format("Write each summary and group label in %s.", language)
end

---@param query string
---@param chat_dir string 検索対象のディレクトリ（絶対パス）
---@param language string?
---@return string
function M.build(query, chat_dir, language)
  return table.concat({
    "Find the past vibing.nvim chats relevant to the query below.",
    "",
    "Query: " .. query,
    "Chat directory: " .. chat_dir,
    "",
    "Every *.md file in that directory is one chat. Search both the user and the assistant parts:",
    "the topic is often named clearly only in the assistant's reply.",
    "",
    "1. Turn the query into 2-4 keywords, including obvious rephrasings. If the query is a",
    "   GitHub PR or issue URL or number, also read its title and branch with `gh pr view` or",
    "   `gh issue view` and search for those.",
    "2. Search the directory with `rg --no-ignore --fixed-strings`, for example",
    "   `rg --no-ignore --fixed-strings -c -e <keyword> -e <keyword> <chat directory>`. The directory",
    "   is usually git-ignored, so a search without `--no-ignore` finds nothing. `--fixed-strings`",
    "   keeps a keyword with characters such as `.`, `(` or `[` literal. If nothing matches,",
    "   rephrase and search again. If too many files match, rank them by match count and keep the",
    "   strongest.",
    "3. Read the matching parts of each candidate and judge whether the chat is actually about",
    "   the query. Drop chats where the keyword appears only in passing. Never list a chat just",
    "   because it is recent: an empty result is a valid answer.",
    "4. Group the survivors by how they relate to the query (for example: handled it directly,",
    "   followed up on it, earlier investigation of the same topic). Use as few groups as fit.",
    "",
    "Use only the read-only tools you are given. Do not modify any file.",
    language_line(language),
    "",
    "End your answer with exactly one JSON code block in this shape and nothing after it:",
    "```json",
    '{"groups": [{"label": "<group>", "chats": [{"path": "<file path>", "summary": "<1-2 lines>"}]}]}',
    "```",
    "Use the path exactly as the tools reported it. Order groups from most to least relevant.",
    'If nothing is relevant, return {"groups": []}.',
  }, "\n")
end

M.language_line = language_line

return M
