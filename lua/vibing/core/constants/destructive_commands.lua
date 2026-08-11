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

---コマンド位置（先頭、または`;` `&&` `||` `|` 改行の直後）に現れるコマンドにマッチするパターン群。
---Bashツールは複数行スクリプトを1つの`command`として渡してくるので、改行も区切りとして扱わないと
---2行目以降のコマンドが素通りする。
---@param ... string Lua pattern（コマンド名部分）
---@return string[]
local function at_command_position(...)
  local patterns = {}
  for _, command in ipairs({ ... }) do
    table.insert(patterns, "^%s*" .. command)
    table.insert(patterns, "[;&|\n]%s*" .. command)
  end
  return patterns
end

---引数を囲むクォート（任意）。`rm -rf "$HOME"`のようにクォートするのはshellcheckも勧める
---普通の書き方で、難読化ではない。
local QUOTE = "[\"']?"

---トークンの終端（空白 or 文字列末尾）。`%f[%s]`だけだと末尾のトークンを取りこぼす。
---@param token string Lua pattern
---@return string[]
local function token_end(token)
  return { token .. "%f[%s]", token .. "$" }
end

---再帰フラグを`prefix`と`suffix`で挟んだパターンに展開する。短縮クラスタ（`-rf` / `-fr` /
---`-R` ...）とGNUのlongform（`--recursive`）は別々に書くしかない（Lua patternに選択がない）。
---longformの前後の`[%-%a%s]*`は`rm -f --recursive /`のように他のフラグと並ぶ形のための穴埋めで、
---フラグらしい文字しか含まないのでターゲットの`.`や`/`を巻き込まない。
---@param prefix string フラグの手前（コマンド名まで）
---@param suffix string フラグの後ろ（ターゲット）
---@return string[]
local function recursive_variants(prefix, suffix)
  return {
    prefix .. "%-%a*[rR]%a*%s+" .. suffix,
    prefix .. "[%-%a%s]*%-%-recursive[%-%a%s]*%s" .. suffix,
  }
end

---`rm`による再帰削除のうち、/ とホームディレクトリを狙うものを展開する。
---`%f[%w]`で単語境界を要求するだけでコマンド位置には固定しない。`find . | xargs rm -rf /`の
---ような形も捕まえたいため。境界だけ見れば`xterm -rf /`の誤検知は防げる。
---@return string[]
local function rm_deny_patterns()
  local TARGETS = {
    -- / , "/" , / --no-preserve-root , /*
    QUOTE .. "/" .. QUOTE .. "%s*$",
    QUOTE .. "/" .. QUOTE .. "%s",
    QUOTE .. "/%*",
    -- ~ , ~/ , $HOME , ${HOME} , and the quoted forms of each
    QUOTE .. "~",
    QUOTE .. "%$HOME",
    QUOTE .. "%${HOME}",
  }

  local patterns = {}
  for _, target in ipairs(TARGETS) do
    for _, pattern in ipairs(recursive_variants("%f[%w]rm%s+", target)) do
      table.insert(patterns, pattern)
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
  -- `git -C /path push ...` や `git --no-pager push ...` のように、gitとpushの間にグローバル
  -- オプションが挟まる形も拾う。クラスにクォートを含めないので、`git commit -m "push ..."` の
  -- ようなメッセージ中の push は跨げない。
  local PREFIX = "git%s+[%-%w%./_%s]*push%s+"
  local SEGMENT = "[^;&|\n]*"
  -- 長形式と短縮クラスタ（`-f`, `-uf` ...）。`--force-with-lease`はいずれにも一致しない。
  local FORCE_FLAGS = { "%-%-force", "%-%a*f%a*" }
  local BRANCHES = { "main", "master" }

  local patterns = {}
  for _, flag in ipairs(FORCE_FLAGS) do
    for _, branch in ipairs(BRANCHES) do
      local branch_token = "%s" .. QUOTE .. branch .. QUOTE
      for _, terminated in ipairs(token_end(branch_token)) do
        -- フラグが先: git push --force origin main
        table.insert(patterns, PREFIX .. SEGMENT .. flag .. "%f[%s]" .. SEGMENT .. terminated)
      end
      for _, terminated in ipairs(token_end(flag)) do
        -- ブランチが先: git push origin main --force
        table.insert(patterns, PREFIX .. SEGMENT .. branch_token .. "%f[%s]" .. SEGMENT .. terminated)
      end
    end
  end
  return patterns
end

---全ルール共通の逃げ道。文面を1か所に集約して、ルールごとの言い回しのブレをなくす。
local ESCAPE_HATCH = "Set permissions.default_deny_rules = false to turn these defaults off."

---@param reason string そのルール固有の説明
---@return string
local function deny_message(reason)
  return reason .. " " .. ESCAPE_HATCH
end

---@type PermissionRule[]
M.DEFAULT_DENY_RULES = {
  {
    tools = { "Bash" },
    patterns = rm_deny_patterns(),
    action = "deny",
    message = deny_message(
      "Recursive deletion of / or the home directory is blocked by vibing.nvim's default deny "
        .. "rules. Delete a specific path instead."
    ),
  },
  {
    tools = { "Bash" },
    patterns = at_command_position("sudo%f[%W]", "doas%f[%W]"),
    action = "deny",
    message = deny_message(
      "Running commands as root is blocked by vibing.nvim's default deny rules. Run it yourself "
        .. "in a terminal."
    ),
  },
  {
    tools = { "Bash" },
    -- dd writing to a raw device, and filesystem creation.
    -- `dd` is anchored at command position so "add"/"odd" cannot trip the rule.
    patterns = at_command_position("dd%f[%W][^;&|]*of=/dev/", "dd%s+if=", "mkfs%f[%W]", "mkfs%."),
    action = "deny",
    message = deny_message(
      "Writing raw devices or creating filesystems is blocked by vibing.nvim's default deny rules."
    ),
  },
  {
    tools = { "Bash" },
    patterns = recursive_variants("chmod%s+[^;&|]*", "0?777"),
    action = "deny",
    message = deny_message(
      "Recursively making a tree world-writable is blocked by vibing.nvim's default deny rules. "
        .. "Set a narrower mode."
    ),
  },
  {
    -- Only force-pushes that name main/master are matched: a Lua pattern cannot know which branch
    -- a bare `git push --force` would land on. `--force-with-lease` is deliberately allowed --
    -- the flag must be followed by whitespace or end there, and "force-with-lease" is neither.
    tools = { "Bash" },
    patterns = git_force_push_patterns(),
    action = "deny",
    message = deny_message(
      "Force-pushing main/master is blocked by vibing.nvim's default deny rules. Use "
        .. "--force-with-lease on a feature branch."
    ),
  },
}

return M
