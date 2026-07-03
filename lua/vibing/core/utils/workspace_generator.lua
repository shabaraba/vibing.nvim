-- lua/vibing/core/utils/workspace_generator.lua
---@class Vibing.Utils.WorkspaceGenerator
---会話内容からworkspaceのdescription（設定言語）とbranch（英語kebab-case）を生成する
---:VibingSetFileTitleのtitle_generator.luaと同様のワンショットAI生成パターン
local M = {}

local language_utils = require("vibing.core.utils.language")

---@param text string
---@return string
function M.sanitize_branch(text)
  text = text:lower()
  text = text:gsub("[^%w%-]+", "-")
  text = text:gsub("%-+", "-")
  text = text:gsub("^%-+", ""):gsub("%-+$", "")
  if #text > 50 then
    text = text:sub(1, 50)
  end
  return text
end

---@param raw_text string ヒアリング済みの会話またはユーザー入力
---@param callback fun(result: {description: string, branch: string}?, error: string?)
function M.generate(raw_text, callback)
  if not raw_text or vim.trim(raw_text) == "" then
    callback(nil, "No description to generate workspace name from")
    return
  end

  local vibing = require("vibing")
  local adapter = vibing.get_adapter()
  local config = vibing.get_config()

  if not adapter then
    callback(nil, "No adapter configured")
    return
  end

  local lang_code = language_utils.get_language_code(config.language, "chat")
  local lang_name = (lang_code and language_utils.language_names[lang_code]) or "English"

  local prompt = raw_text
    .. "\n\n"
    .. "Based on the above, respond with exactly two lines in this format:\n"
    .. "DESCRIPTION: <a concise description of the task, in "
    .. lang_name
    .. ", max 40 characters>\n"
    .. "BRANCH: <a git branch name in English, kebab-case, lowercase, max 40 characters, no spaces>\n"
    .. "Respond with ONLY these two lines, nothing else."

  local collected = ""

  local opts = {
    permission_mode = config.permissions and config.permissions.mode or "acceptEdits",
    permissions_allow = config.permissions and config.permissions.allow or {},
    permissions_deny = config.permissions and config.permissions.deny or {},
  }

  adapter:stream(prompt, opts, function(chunk)
    collected = collected .. chunk
  end, function(response)
    if response.error then
      callback(nil, response.error)
      return
    end

    local text = collected ~= "" and collected or (response.content or "")
    local description = text:match("DESCRIPTION:%s*(.-)%s*\n") or text:match("DESCRIPTION:%s*(.-)%s*$")
    local branch = text:match("BRANCH:%s*(.-)%s*\n") or text:match("BRANCH:%s*(.-)%s*$")

    if not description or not branch or vim.trim(description) == "" or vim.trim(branch) == "" then
      callback(nil, "Failed to parse description/branch from AI response")
      return
    end

    local sanitized_branch = M.sanitize_branch(branch)
    if sanitized_branch == "" then
      callback(nil, "Failed to parse description/branch from AI response")
      return
    end

    callback({
      description = vim.trim(description),
      branch = sanitized_branch,
    }, nil)
  end)
end

return M
