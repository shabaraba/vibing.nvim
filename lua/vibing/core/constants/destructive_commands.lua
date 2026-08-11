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

---コマンド位置（先頭、または`;` `&&` `||` `|` 改行の直後）に現れる`command`にマッチするパターン群。
---Bashツールは複数行スクリプトを1つの`command`として渡してくるので、改行も区切りとして扱わないと
---2行目以降のコマンドが素通りする。
---@param command string Lua pattern（コマンド名部分）
---@return string[]
local function at_command_position(command)
  return {
    "^%s*" .. command,
    "[;&|\n]%s*" .. command,
  }
end

---トークンの終端（空白 or 文字列末尾）。`%f[%s]`だけだと末尾のトークンを取りこぼす。
---@param token string Lua pattern
---@return string[]
local function token_end(token)
  return { token .. "%f[%s]", token .. "$" }
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

---main/masterへのforce pushを表すパターン群を展開する。
---`git push`はフラグの位置を問わないので、`--force origin main`と`origin main --force`の
---両方の並び順を生成する必要がある（Lua patternに選択がないため）。
---ブランチ名は空白/末尾で区切られたトークンとしてのみ一致させる。`%f[%W]`だけだと`-`も境界に
---なってしまい、`main-v2`のような別ブランチを誤検知する。
---@return string[]
local function git_force_push_patterns()
  local PREFIX = "git%s+push%s+"
  local SEGMENT = "[^;&|\n]*"
  -- 長形式と短縮クラスタ（`-f`, `-uf` ...）。`--force-with-lease`はいずれにも一致しない。
  local FORCE_FLAGS = { "%-%-force", "%-%a*f%a*" }
  local BRANCHES = { "main", "master" }

  local patterns = {}
  for _, flag in ipairs(FORCE_FLAGS) do
    for _, branch in ipairs(BRANCHES) do
      for _, branch_token in ipairs(token_end("%s" .. branch)) do
        -- フラグが先: git push --force origin main
        table.insert(patterns, PREFIX .. SEGMENT .. flag .. "%f[%s]" .. SEGMENT .. branch_token)
      end
      for _, flag_token in ipairs(token_end(flag)) do
        -- ブランチが先: git push origin main --force
        table.insert(patterns, PREFIX .. SEGMENT .. "%s" .. branch .. "%f[%s]" .. SEGMENT .. flag_token)
      end
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
      -- dd writing to a raw device, and filesystem creation.
      -- `dd` is anchored at command position so "add"/"odd" cannot trip the rule.
      at_command_position("dd%f[%W][^;&|]*of=/dev/"),
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
    -- the flag must be followed by whitespace or end there, and "force-with-lease" is neither.
    tools = { "Bash" },
    patterns = git_force_push_patterns(),
    action = "deny",
    message = "Force-pushing main/master is blocked by vibing.nvim's default deny rules. "
      .. "Use --force-with-lease on a feature branch, or set permissions.default_deny_rules = false.",
  },
}

return M
