---Chat excerpt builder for lightweight utility calls (title generation).
---@class Vibing.Utils.ChatExcerpt
---
---チャットバッファから抽出した会話は「バッファに描画されたテキストそのもの」なので、
---assistant セクションの大半がツール実況（`💻 Bash(...)`, `⏺ Read(...)`, `⎿ 結果`）で占められる。
---それをそのままタイトル生成に渡すと、モデルが見るのはシェルコマンドの羅列になり、
---会話の主題ではなく終盤に実行したコマンドがタイトルになる。
---このモジュールは描画ノイズを落として「人間が書いた／読んだ文」だけを残す。
local M = {}

-- Fallback marker glyphs. 実際のマーカーは config.ui.tool_markers でユーザーが差し替えるので、
-- 構造マッチ（`<記号> ToolName(`）と設定値の両方を併用する。
local BUILTIN_MARKERS = { "⏺", "📄", "💻", "🔧", "✳", "☒", "☐", "⎿", "→", "▶" }

-- 会話の主題を一切含まない定型メッセージ。抜粋に混ざるとタイトルを乗っ取る。
local BOILERPLATE_MESSAGES = {
  ["continue from where you left off."] = true,
  ["continue from where you left off"] = true,
  ["allow_once"] = true,
  ["deny_once"] = true,
  ["allow_for_session"] = true,
  ["deny_for_session"] = true,
}

---定型メッセージ判定。自動継続プロンプトは設定で差し替えられるので、既定値のハードコードに
---加えて実際の設定値も見る（差し替えた人だけ「Continue…」が主題として残る、を避ける）。
---@param cleaned string
---@return boolean
local function is_boilerplate(cleaned)
  local lowered = cleaned:lower()
  if BOILERPLATE_MESSAGES[lowered] then
    return true
  end
  local ok, config_mod = pcall(require, "vibing.config")
  if not ok then
    return false
  end
  local ok_get, config = pcall(config_mod.get)
  local agent = ok_get and config and config.agent
  local prompt = agent and agent.auto_resume_on_limit and agent.auto_resume_on_limit.prompt
  return type(prompt) == "string" and vim.trim(prompt):lower() == lowered
end

---@return string[]
local function marker_glyphs()
  local glyphs = {}
  local seen = {}
  for _, g in ipairs(BUILTIN_MARKERS) do
    glyphs[#glyphs + 1] = g
    seen[g] = true
  end
  local ok, config_mod = pcall(require, "vibing.config")
  if ok then
    local ok_get, config = pcall(config_mod.get)
    local markers = ok_get and config and config.ui and config.ui.tool_markers
    if type(markers) == "table" then
      for _, g in pairs(markers) do
        if type(g) == "string" and g ~= "" and not seen[g] then
          glyphs[#glyphs + 1] = g
          seen[g] = true
        end
      end
    end
  end
  return glyphs
end

---ツール呼び出しヘッダー行かどうか。
---描画形式は `<marker> <ToolName>(<summary>` （summary は複数行になりうる）。
---マーカーはユーザー設定で任意の記号になるため、設定済みマーカーによる判定に加えて
---「非ASCIIの記号1トークン + 識別子 + `(`」という構造でも拾う。
---
---非ASCIIを要求するのが肝。ここを「英数字を含まない先頭トークン」まで緩めると、
---`- fix parse(input)` のような markdown 箇条書きがツール行と誤判定され、
---ユーザーの依頼そのものが抜粋から消える。ASCII記号のマーカーを使う人は
---`config.ui.tool_markers` に載っているので glyphs 側で拾える。
---
---`allow_glyph_prefix` は「マーカーで始まるだけ」の緩い判定を使うかどうか。構造マッチと違って
---行の中身を一切見ないので、user の発言に対しては使ってはいけない: `→ ログインを直して` や
---`💻 環境構築で詰まってる` のような、記号を箇条書き代わりに使った依頼文がそのまま消え、
---1行の依頼ならメッセージごと抜粋から落ちる（このPRが直そうとしている症状そのもの）。
---
---構造マッチのほうは `allow_glyph_prefix` に関わらず user にも効く。これは承知の上で、
---`⏺ Bash(npm test)` のような描画済みツール行が user セクションに混ざった場合に落とすため。
---代償として `→ fix(login)`（記号+識別子+`(` がそのまま揃った依頼文）は消える。`→ fix login(x)`
---のように識別子と `(` の間に何か挟まれば残るので、実際に踏む形はかなり狭い。
---@param trimmed string
---@param glyphs string[]
---@param allow_glyph_prefix boolean
---@return boolean
local function is_tool_header(trimmed, glyphs, allow_glyph_prefix)
  local head, name = trimmed:match("^(%S+)%s+([%w_][%w_%.:%-]*)%(")
  if head and name and not head:match("[%w]") and head:match("[\128-\255]") then
    return true
  end
  if not allow_glyph_prefix then
    return false
  end
  for _, g in ipairs(glyphs) do
    if trimmed:sub(1, #g) == g then
      return true
    end
  end
  return false
end

---括弧の釣り合い（開き - 閉じ）。ツールヘッダーの複数行引数の終端検出に使う。
---
---引用符の中の括弧は数えない。`💻 Bash(echo ')'` のような行でここが先に0になると、
---続く `git rebase origin/main)` が地の文として抜粋に残り、そのコマンドがタイトルになる。
---行をまたぐ引用符までは追わない（そこまで来るとシェルのパーサが要る）が、
---1行で閉じる引用が実際にはほとんどで、追えなかった場合も次の空行で打ち切られる。
---@param s string
---@return integer
local function paren_balance(s)
  s = s:gsub("\\.", "") -- エスケープされた引用符が対を崩さないよう先に落とす
  s = s:gsub("'[^']*'", "")
  s = s:gsub('"[^"]*"', "")
  local _, opens = s:gsub("%(", "")
  local _, closes = s:gsub("%)", "")
  return opens - closes
end

---@param text string
---@param glyphs string[]
---@param allow_glyph_prefix boolean マーカーで始まるだけの行もツール実況として落とすか（assistant のみ）
---@return string
local function clean_with(text, glyphs, allow_glyph_prefix)
  -- HTMLコメントは複数行にまたがりうるので行分割の前に落とす
  text = text:gsub("<!%-%-.-%-%->", "")

  local out = {}
  local lines = vim.split(text, "\n", { plain = true })
  local i = 1

  while i <= #lines do
    local line = lines[i]
    local trimmed = vim.trim(line)

    if trimmed:match("^```") then
      -- フェンス済みコードブロックは丸ごと捨てる（閉じていなければ以降すべて）
      i = i + 1
      while i <= #lines and not vim.trim(lines[i]):match("^```") do
        i = i + 1
      end
      i = i + 1
    elseif trimmed:sub(1, #"⎿") == "⎿" then
      -- ツール結果ブロック: 続く行は5スペース以上のインデントで継続する
      -- （結果テキスト自身が字下げを持つ場合は5スペースより深くなる）
      i = i + 1
      while i <= #lines and lines[i]:match("^     ") do
        i = i + 1
      end
    elseif trimmed:match("Tool approval required") then
      -- 承認UIは1ブロックまるごと落とす。`Tool:` / `Command:` / `File:` 等の行まで含めるため、
      -- 選択肢行を個別に消すのではなく締めの一行まで読み飛ばす。ユーザーは選択肢を1つ残して
      -- 送るので、残った `allow_once` もこの範囲に入る。
      i = i + 1
      while i <= #lines and not vim.trim(lines[i]):match("^Please select and press") do
        i = i + 1
      end
      i = i + 1
    elseif is_tool_header(trimmed, glyphs, allow_glyph_prefix) then
      -- ヘッダーの引数は複数行になりうる（Bashの複数行コマンド等）。括弧の釣り合いで終端を探す。
      -- 空行でも打ち切るのは、`case x)` のように釣り合わない括弧を含むコマンドで
      -- 後続の地の文まで丸ごと食べてしまわないため。
      local balance = paren_balance(line)
      i = i + 1
      while i <= #lines and balance > 0 and vim.trim(lines[i]) ~= "" do
        balance = balance + paren_balance(lines[i])
        i = i + 1
      end
    elseif
      trimmed:match("^@file:")
      or trimmed:match("^Context:")
      or trimmed:match("^%*%*Error:%*%*")
      or trimmed:match("^%*Session has been reset")
      -- 承認ブロックはひとつ上の分岐で丸ごと落とすが、締めの行が消された状態で送られた場合に
      -- 選択肢だけが残るので、個別のパターンも残しておく
      or trimmed:match("^%d+%.%s+%a+_once%f[%W]")
      or trimmed:match("^%d+%.%s+%a+_for_session%f[%W]")
      or trimmed:match("^Please select and press")
      or trimmed:match("^Please answer the question and press")
    then
      i = i + 1
    else
      out[#out + 1] = line
      i = i + 1
    end
  end

  local cleaned = table.concat(out, "\n")
  cleaned = cleaned:gsub("\n%s*\n%s*\n+", "\n\n")
  return vim.trim(cleaned)
end

---1メッセージ分の描画テキストから、タイトル生成に意味のある地の文だけを残す。
---落とすもの: ツール呼び出しヘッダーとその複数行引数、ツール結果ブロック、フェンス済みコードブロック、
---HTMLコメント（patch/subagent マーカー等）、`@file:` コンテキスト行、
---レート制限などのシステム通知、ツール承認UIのブロック。
---
---assistant の描画テキスト向け。user の発言には `M.clean_user` を使う。
---@param text string?
---@return string
function M.clean(text)
  if not text or text == "" then
    return ""
  end
  return clean_with(text, marker_glyphs(), true)
end

---`M.clean` の user 発言版。マーカーで始まるだけの行は落とさない（理由は `is_tool_header`）。
---@param text string?
---@return string
function M.clean_user(text)
  if not text or text == "" then
    return ""
  end
  return clean_with(text, marker_glyphs(), false)
end

---ツール実況行かどうか。`first_title_line`（モデルの応答側）と抜粋のクリーニングで
---同じ判定を使うための公開版。
---@param line string
---@return boolean
function M.is_tool_line(line)
  -- ここはモデル自身が返したタイトル候補1行が対象なので、緩いマーカー前方一致で構わない。
  return is_tool_header(vim.trim(line), marker_glyphs(), true)
end

---@param s string
---@param n integer
---@return string
local function truncate(s, n)
  if vim.fn.strchars(s) > n then
    return vim.fn.strcharpart(s, 0, n) .. "…"
  end
  return s
end

-- user メッセージは「何をしようとしたか」そのものなので厚く、assistant は文脈補強なので薄く取る。
local USER_MESSAGE_CHARS = 600
local ASSISTANT_MESSAGE_CHARS = 400
local MAX_USER_MESSAGES = 8
local MAX_ASSISTANT_MESSAGES = 2
local MAX_TOTAL_CHARS = 6000

---会話からタイトル生成用の抜粋を作る。
---user メッセージを主情報として全件（多すぎる場合は先頭側と末尾側）取り、
---assistant は冒頭の応答だけを短く添える。末尾数件だけを取る方式をやめたのは、
---終盤の雑務（「マージしてcleanup」等）が会話の主題を上書きしてしまうため。
---@param conversation {role: string, content: string}[]
---@return string
function M.build(conversation)
  local users, assistants = {}, {}
  -- マーカー一覧は設定を読むので、メッセージごとではなく1会話につき1回だけ組み立てる
  local glyphs = marker_glyphs()

  for _, msg in ipairs(conversation or {}) do
    -- マーカー前方一致による除去は assistant 側だけ。user の発言に効かせると、記号を
    -- 箇条書き代わりに使った依頼文がそのまま消える。
    local cleaned = msg.content
        and msg.content ~= ""
        and clean_with(msg.content, glyphs, msg.role ~= "user")
      or ""
    if cleaned ~= "" and not is_boilerplate(cleaned) then
      if msg.role == "user" then
        users[#users + 1] = cleaned
      elseif msg.role == "assistant" then
        assistants[#assistants + 1] = cleaned
      end
    end
  end

  -- 役割ごとに節を分ける。「主題は user が頼んだこと」という指示を、
  -- プロンプト文だけでなく抜粋の構造そのものでモデルに伝えるため。
  -- 見出しに `#` を使わないのは、メッセージ本文中の markdown 見出しと混ざらないようにするため。
  local parts = { "[USER REQUESTS — this is the subject of the conversation]" }

  local function add_user(text)
    parts[#parts + 1] = "- " .. truncate(text, USER_MESSAGE_CHARS)
  end

  if #users == 0 then
    parts[#parts + 1] = "- (none)"
  elseif #users <= MAX_USER_MESSAGES then
    for _, text in ipairs(users) do
      add_user(text)
    end
  else
    -- 主題を固定する先頭側を残し、直近の文脈も落とさない
    local head = math.ceil(MAX_USER_MESSAGES / 2)
    local tail = MAX_USER_MESSAGES - head
    for j = 1, head do
      add_user(users[j])
    end
    parts[#parts + 1] = "- (…)"
    for j = #users - tail + 1, #users do
      add_user(users[j])
    end
  end

  -- 冒頭の assistant 応答だけを添える。末尾の応答は「マージと後片付けが完了しました」のような
  -- 締めの報告になりがちで、それを入れると主題ではなく後始末がタイトルになる。
  if #assistants > 0 then
    parts[#parts + 1] = ""
    parts[#parts + 1] = "[ASSISTANT REPLIES — background only, not the subject]"
    for j = 1, math.min(MAX_ASSISTANT_MESSAGES, #assistants) do
      parts[#parts + 1] = "- " .. truncate(assistants[j], ASSISTANT_MESSAGE_CHARS)
    end
  end

  return truncate(table.concat(parts, "\n"), MAX_TOTAL_CHARS)
end

return M
