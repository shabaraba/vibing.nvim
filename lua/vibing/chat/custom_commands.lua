local notify = require("vibing.utils.notify")

---@class Vibing.CustomCommand
---@field name string コマンド名（ファイル名から生成、例："git-commit"）
---@field description string コマンド説明（# タイトル行またはファイル名）
---@field source "project"|"user"|"plugin" コマンドソース
---@field file_path string Markdownファイルのフルパス
---@field content string Markdownファイル全体の内容
---@field plugin_name string? プラグイン名（pluginソースの場合のみ、例："dev-org"）

---@class Vibing.CustomCommands
local M = {}

---キャッシュ（nilの場合は未初期化）
---@type Vibing.CustomCommand[]?
M._cache = nil

---ファイルパスからプラグイン名を抽出
---@param file_path string ファイルパス
---@return string? plugin_name プラグイン名（抽出できない場合はnil）
local function extract_plugin_name(file_path)
  -- marketplaces: ~/.claude/plugins/marketplaces/{marketplace}/plugins/{plugin}/commands/*.md
  local marketplace_match = file_path:match("/marketplaces/[^/]+/plugins/([^/]+)/commands/")
  if marketplace_match then
    return marketplace_match
  end

  -- cache: ~/.claude/plugins/cache/{owner}/{plugin}/{version}/commands/*.md
  local cache_match = file_path:match("/cache/[^/]+/([^/]+)/[^/]+/commands/")
  if cache_match then
    return cache_match
  end

  return nil
end

---Markdownファイルをパースしてコマンド情報を抽出
---ファイル名からコマンド名を生成し、最初の#行を説明として使用
---@param file_path string Markdownファイルのフルパス
---@return {name: string, description: string, content: string}?
function M._parse_markdown(file_path)
  -- ファイルが読み取れるかチェック
  if vim.fn.filereadable(file_path) ~= 1 then
    return nil
  end

  -- ファイル読み込み
  local ok, lines = pcall(vim.fn.readfile, file_path)
  if not ok or not lines then
    return nil
  end

  -- ファイル名からコマンド名を抽出（例: "git-commit.md" → "git-commit"）
  local filename = vim.fn.fnamemodify(file_path, ":t")
  local name = filename:gsub("%.md$", "")

  -- 最初の# 行を説明として抽出
  local description = name -- デフォルトはファイル名
  for _, line in ipairs(lines) do
    local match = line:match("^#%s+(.+)$")
    if match then
      description = match
      break
    end
  end

  -- Markdown全体の内容
  local content = table.concat(lines, "\n")

  return {
    name = name,
    description = description,
    content = content,
  }
end

---.claude/commands/*.md をスキャンしてカスタムコマンドを検出
---project（カレントディレクトリ）、user（ホームディレクトリ）、プラグインマーケットの全てをスキャン
---@return Vibing.CustomCommand[] 検出されたカスタムコマンドの配列
function M.scan()
  local commands = {}

  -- スキャン対象パス
  local paths = {
    { dir = vim.fn.getcwd() .. "/.claude/commands/", source = "project" },
    { dir = vim.fn.expand("~/.claude/commands/"), source = "user" },
  }

  for _, path_info in ipairs(paths) do
    -- ディレクトリが存在するかチェック
    if vim.fn.isdirectory(path_info.dir) == 1 then
      -- *.md ファイルを検索
      local files = vim.fn.glob(path_info.dir .. "*.md", false, true)
      for _, file in ipairs(files) do
        local success, parsed = pcall(M._parse_markdown, file)
        if success and parsed then
          table.insert(commands, {
            name = parsed.name,
            description = parsed.description,
            source = path_info.source,
            file_path = file,
            content = parsed.content,
          })
        else
          notify.warn(string.format("Failed to parse: %s", file))
        end
      end
    end
  end

  -- プラグインマーケットのコマンドもスキャン
  local plugin_marketplaces = vim.fn.expand("~/.claude/plugins/marketplaces/")
  if vim.fn.isdirectory(plugin_marketplaces) == 1 then
    -- 全マーケットプレイスをスキャン
    local marketplaces = vim.fn.glob(plugin_marketplaces .. "*", false, true)
    for _, marketplace in ipairs(marketplaces) do
      if vim.fn.isdirectory(marketplace) == 1 then
        -- 各プラグインのcommandsディレクトリをスキャン
        local plugin_commands = vim.fn.glob(marketplace .. "/plugins/*/commands/*.md", false, true)
        for _, file in ipairs(plugin_commands) do
          local success, parsed = pcall(M._parse_markdown, file)
          if success and parsed then
            table.insert(commands, {
              name = parsed.name,
              description = parsed.description,
              source = "plugin",
              file_path = file,
              content = parsed.content,
              plugin_name = extract_plugin_name(file),
            })
          end
        end
      end
    end
  end

  -- プラグインキャッシュ (--add-dir含む) もスキャン
  local plugin_cache = vim.fn.expand("~/.claude/plugins/cache/")
  if vim.fn.isdirectory(plugin_cache) == 1 then
    -- {owner}/{plugin}/{version}/commands/*.md パターンでスキャン
    local cache_plugin_commands = vim.fn.glob(plugin_cache .. "*/*/*/commands/*.md", false, true)
    for _, file in ipairs(cache_plugin_commands) do
      local success, parsed = pcall(M._parse_markdown, file)
      if success and parsed then
        table.insert(commands, {
          name = parsed.name,
          description = parsed.description,
          source = "plugin",
          file_path = file,
          content = parsed.content,
          plugin_name = extract_plugin_name(file),
        })
      end
    end
  end

  return commands
end

---全カスタムコマンドを取得（キャッシュから、またはスキャン）
---キャッシュがnil の場合は自動的にscan()を実行
---@return Vibing.CustomCommand[]
function M.get_all()
  if not M._cache then
    M._cache = M.scan()
  end
  return M._cache
end

---キャッシュをクリアして強制再スキャン
function M.clear_cache()
  M._cache = nil
end

return M
