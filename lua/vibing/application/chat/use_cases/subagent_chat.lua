---@class Vibing.Application.Chat.UseCases.SubagentChat
---subagentとの継続対話用チャットを開くUse Case
---
---forkと違い、session_idは**恒久的に**共有される。subagentのtranscriptは親セッションIDの
---ディレクトリ配下に置かれているため、`--fork-session`で新しいsession_idを切ると
---`No transcript found for agent ID` になりSendMessageで再開できない（実CLIで確認済み）。
---そのため`forked_from`は決して書かず、常に`--resume <親のsession_id>`のまま送る。
local M = {}

local notify = require("vibing.core.utils.notify")
local ChatSession = require("vibing.domain.chat.session")
local FileManager = require("vibing.presentation.chat.modules.file_manager")
local Frontmatter = require("vibing.infrastructure.storage.frontmatter")
local InheritedFrontmatter = require("vibing.application.chat.inherited_frontmatter")
local Fs = require("vibing.core.utils.fs")

---@param save_dir string
---@param agent_id string
---@return string? path 同じsubagentに紐づく既存チャット
local function find_existing_chat(save_dir, agent_id)
  for _, path in ipairs(vim.fn.glob(vim.fs.joinpath(save_dir, "*.md"), false, true)) do
    local ok, content = pcall(vim.fn.readfile, path)
    if ok and content then
      local frontmatter = Frontmatter.parse(table.concat(content, "\n"))
      if frontmatter and frontmatter.subagent_id == agent_id then
        return path
      end
    end
  end
  return nil
end

---@param source_path string
---@param agent_id string
---@param save_dir string
---@return string filename
local function generate_filename(source_path, agent_id, save_dir)
  local prefix = string.format("%s-agent-%s", vim.fn.fnamemodify(source_path, ":t:r"), agent_id:sub(1, 8))
  local filename = prefix .. ".md"

  local suffix = 2
  while vim.fn.filereadable(vim.fs.joinpath(save_dir, filename)) == 1 do
    filename = string.format("%s-%d.md", prefix, suffix)
    suffix = suffix + 1
  end

  return filename
end

---フロントマターをコピー（session_idは親のまま使い続け、subagent_idを追加）
---権限もconfigの既定ではなく親の姿勢を引き継ぐ（同じ生きたセッションの続きなので）
---@param source_frontmatter table
---@param agent_id string
---@param config table
---@return table
function M._copy_frontmatter(source_frontmatter, agent_id, config)
  local frontmatter = InheritedFrontmatter.from_source(source_frontmatter, config)
  -- forkと違い分岐させない印。session_idは親のまま据え置かれる
  frontmatter.subagent_id = agent_id
  return frontmatter
end

---@param chat_buffer Vibing.ChatBuffer 呼び出し元のチャット
---@param agent_id string
---@return Vibing.ChatSession? session
---@return string? existing_path 既存チャットが見つかった場合のパス
function M.execute(chat_buffer, agent_id)
  if not chat_buffer or not chat_buffer.file_path then
    notify.error("No valid chat buffer")
    return nil, nil
  end
  if type(agent_id) ~= "string" or agent_id == "" then
    notify.error("No subagent id given")
    return nil, nil
  end

  local vibing = require("vibing")
  local config = vibing.get_config()

  local save_dir = FileManager.get_save_directory(config.chat)
  Fs.ensure_dir(save_dir)

  -- 同じsubagentに2つ目のバッファを作ると、同じsession_idを共有するバッファ同士が
  -- 送信を奪い合う。既にあるなら開き直す
  local existing = find_existing_chat(save_dir, agent_id)
  if existing then
    return nil, existing
  end

  local ok, source_content = pcall(vim.fn.readfile, chat_buffer.file_path)
  if not ok or not source_content then
    notify.error("Failed to read source file: " .. tostring(source_content))
    return nil, nil
  end

  local source_frontmatter = Frontmatter.parse(table.concat(source_content, "\n"))
  if not source_frontmatter then
    notify.error("Failed to parse source frontmatter")
    return nil, nil
  end
  if not source_frontmatter.session_id or source_frontmatter.session_id == "~" then
    notify.error("This chat has no session yet — send a message first")
    return nil, nil
  end

  local frontmatter = M._copy_frontmatter(source_frontmatter, agent_id, config)

  local session = ChatSession:new({
    session_id = source_frontmatter.session_id,
    frontmatter = frontmatter,
    working_dir = source_frontmatter.working_dir,
  })

  local path = vim.fs.joinpath(save_dir, generate_filename(chat_buffer.file_path, agent_id, save_dir))
  session:set_file_path(path)

  -- 本文は引き継がない。親の履歴はセッション側が持っているし、このバッファはsubagentとの
  -- やり取りだけを写すほうが読みやすい。
  -- ここで書くのは見出しであって `<!-- subagent: ... -->` マーカーではない点に注意。
  -- マーカーを書くとsubagent_finderがこのバッファ自身を候補として拾ってしまう
  local body = string.format("\nBound to subagent `%s`.\n", agent_id)
  local content = Frontmatter.serialize(frontmatter, body)
  if vim.fn.writefile(vim.split(content, "\n"), path) ~= 0 then
    notify.error("Failed to write subagent chat file: " .. path)
    return nil, nil
  end

  return session, nil
end

return M
