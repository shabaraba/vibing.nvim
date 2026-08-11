---@class Vibing.Core.DestructiveCommandsConstants
---Bashコマンドのうち、デフォルトで拒否する破壊的操作のルール定義。
---
---承認プロンプトは主防御にならない（ユーザーは大半を素通り承認する）ため、環境層に決定論的な
---境界を先に引く。これらは`permissions.rules`の先頭に差し込まれ、deny優先で評価される。
---`permissions.default_deny_rules = false`で無効化できる。
---
---**パターンはLua patternであって正規表現ではない**。`-`は量指定子、`$`は行末アンカーなので、
---リテラルとして書きたい文字は`%`でエスケープすること（`^rm -rf /`は "rm" + 空白0個以上 + "rf /"
---と解釈され、実際の`rm -rf /`にマッチしない）。
---
---意図的に`^`で先頭固定していない。`cd /tmp && sudo rm -rf /`のように、パイプや`&&`の後ろに
---現れる破壊的コマンドも捕まえるため。
local M = {}

---コマンド位置（行頭、または`;` `&&` `||` `|` の直後）に現れる`command`にマッチするパターン群
---@param command string Lua pattern（コマンド名部分）
---@return string[]
local function at_command_position(command)
  return {
    "^%s*" .. command,
    "[;&|]%s*" .. command,
  }
end

---複数のパターン配列を連結する
---@param ... string[]
---@return string[]
local function concat(...)
  local result = {}
  for _, list in ipairs({ ... }) do
    for _, pattern in ipairs(list) do
      table.insert(result, pattern)
    end
  end
  return result
end

---`rm`の再帰削除フラグ（`-rf` / `-fr` / `-Rf` ...）
local RM_RECURSIVE = "rm%s+%-%a*[rR]%a*%s+"

---@type PermissionRule[]
M.DEFAULT_DENY_RULES = {
  {
    tools = { "Bash" },
    patterns = {
      -- rm -rf / , rm -rf /* , rm -rf / --no-preserve-root
      RM_RECURSIVE .. "/%s*$",
      RM_RECURSIVE .. "/%s",
      RM_RECURSIVE .. "/%*",
      -- rm -rf ~ , rm -rf ~/ , rm -rf $HOME
      RM_RECURSIVE .. "~",
      RM_RECURSIVE .. "%$HOME",
      RM_RECURSIVE .. "%${HOME}",
    },
    action = "deny",
    message = "Recursive deletion of / or the home directory is blocked by vibing.nvim's default "
      .. "deny rules. Delete a specific path instead, or set permissions.default_deny_rules = false.",
  },
  {
    tools = { "Bash" },
    patterns = concat(at_command_position("sudo%f[%W]"), at_command_position("doas%f[%W]")),
    action = "deny",
    message = "Running commands as root is blocked by vibing.nvim's default deny rules. "
      .. "Run it yourself in a terminal, or set permissions.default_deny_rules = false.",
  },
  {
    tools = { "Bash" },
    patterns = concat(
      -- dd writing to a raw device, and filesystem creation
      { "dd%s+[^;&|]*of=/dev/" },
      at_command_position("dd%s+if="),
      at_command_position("mkfs%f[%W]"),
      at_command_position("mkfs%.")
    ),
    action = "deny",
    message = "Writing raw devices or creating filesystems is blocked by vibing.nvim's default "
      .. "deny rules. Set permissions.default_deny_rules = false if you really need this.",
  },
  {
    tools = { "Bash" },
    patterns = {
      "chmod%s+[^;&|]*%-%a*[rR]%a*%s+0?777",
      "chmod%s+[^;&|]*%-%-recursive%s+0?777",
    },
    action = "deny",
    message = "Recursively making a tree world-writable is blocked by vibing.nvim's default deny "
      .. "rules. Set a narrower mode, or set permissions.default_deny_rules = false.",
  },
  {
    -- Only force-pushes that name main/master are matched: a Lua pattern cannot know which branch
    -- a bare `git push --force` would land on. `--force-with-lease` is deliberately allowed —
    -- `%f[%s]` requires whitespace right after "force".
    tools = { "Bash" },
    patterns = {
      "git%s+push%s+[^;&|]*%-%-force%f[%s][^;&|]*%f[%w]main%f[%W]",
      "git%s+push%s+[^;&|]*%-%-force%f[%s][^;&|]*%f[%w]master%f[%W]",
      "git%s+push%s+[^;&|]*%-%a*f%a*%f[%s][^;&|]*%f[%w]main%f[%W]",
      "git%s+push%s+[^;&|]*%-%a*f%a*%f[%s][^;&|]*%f[%w]master%f[%W]",
    },
    action = "deny",
    message = "Force-pushing main/master is blocked by vibing.nvim's default deny rules. "
      .. "Use --force-with-lease on a feature branch, or set permissions.default_deny_rules = false.",
  },
}

return M
