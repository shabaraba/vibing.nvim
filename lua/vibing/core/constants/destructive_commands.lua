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
---
---マッチは大文字小文字を区別する（`rule_checker`が`command`をそのまま`:match`する）。ここで
---扱うのはいずれも小文字固定のUnixコマンド名なので、これは意図的な割り切り。
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

---`rm`の再帰削除フラグ。短縮形（`-rf` / `-fr` / `-Rf` ...）とGNUのlongform（`--recursive`）を
---それぞれ別パターンとして持つ。Lua patternに選択（`|`）がないため、ターゲットごとに両方を展開する。
---`[%-%a%s]*`はフラグらしい文字しか含まないので、`rm --recursive ./dist/`のターゲット部分を
---巻き込んでしまうことがない（`.`や`/`がクラスに入っていない）。
local RM_RECURSIVE_FLAGS = {
  "rm%s+%-%a*[rR]%a*%s+",
  "rm%s+[%-%a%s]*%-%-recursive[%-%a%s]*%s",
}

---再帰削除フラグ × 危険なターゲットの組み合わせを展開する
---@param targets string[] Lua pattern（フラグの直後に続く部分）
---@return string[]
local function rm_patterns(targets)
  local patterns = {}
  for _, flags in ipairs(RM_RECURSIVE_FLAGS) do
    for _, target in ipairs(targets) do
      table.insert(patterns, flags .. target)
    end
  end
  return patterns
end

---@type PermissionRule[]
M.DEFAULT_DENY_RULES = {
  {
    tools = { "Bash" },
    patterns = rm_patterns({
      -- / , /* , / --no-preserve-root
      "/%s*$",
      "/%s",
      "/%*",
      -- ~ , ~/ , $HOME , ${HOME}
      "~",
      "%$HOME",
      "%${HOME}",
    }),
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
