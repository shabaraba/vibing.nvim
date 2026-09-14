---@class Vibing.PatchViewer.Highlights
---diffペインの配色。VSCodeの diff editor と同じ考え方を取る:
---
---  * **前景色は一切触らない**。構文ハイライトを残すのが目的で、多くのカラースキームは
---    `DiffAdd` / `DiffChange` に `fg` を置くため、変更行だけ単色に潰れてしまう
---  * 行は薄く、変わった文字だけ濃く着色する
---  * 色は固定値ではなく、そのカラースキームの Normal 背景に緑/赤を混ぜて作る
---
---当てるのは `winhighlight` で、これは **window-local**。だからユーザーの配色は
---どこも書き換わらず、フロートを閉じれば何も残らない。
---
---Vimのdiffモードには「削除された行」という色が無い。片側にしか無い行はどちらの窓でも
---`DiffAdd` になり、`DiffDelete` は穴埋め行の色でしかない。窓ごとに割り当てを変えられる
---ことが効くのはここで、Beforeの `DiffAdd` を赤、Afterの `DiffAdd` を緑に向けると
---VSCodeと同じ「左が赤・右が緑」になる。
local M = {}

---行全体はうっすら、変わった文字はしっかり。VSCodeの insertedLine/insertedText 相当
local LINE_ALPHA = 0.16
local TEXT_ALPHA = 0.40
---穴埋めの斜線。「ここには何も無い」を示すだけなので色は付けず、地に沈める
local FILLER_ALPHA = 0.22
---unifiedの行番号と `@@` の行。読めるが目を引かない程度に地へ寄せる
local GUTTER_ALPHA = 0.45
local HUNK_FG_ALPHA = 0.55
local HUNK_BG_ALPHA = 0.07

local FALLBACK = {
  bg_dark = 0x1E1E1E,
  bg_light = 0xFFFFFF,
  fg_dark = 0xCCCCCC,
  fg_light = 0x333333,
  add = 0x6AA84F,
  del = 0xD16969,
}

---@param fg number
---@param bg number
---@param alpha number 0..1 のfgの割合
---@return number
function M.blend(fg, bg, alpha)
  local function channel(shift)
    local f = math.floor(fg / shift) % 256
    local b = math.floor(bg / shift) % 256
    return math.floor(f * alpha + b * (1 - alpha) + 0.5)
  end
  return channel(65536) * 65536 + channel(256) * 256 + channel(1)
end

---最初に見つかった定義済みの色を返す
---@param names string[]
---@param key "fg"|"bg"
---@return number?
local function first_color(names, key)
  for _, name in ipairs(names) do
    local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = name, link = false })
    if ok and hl and hl[key] then
      return hl[key]
    end
  end
  return nil
end

---カラースキームから今の色を取り直して group を定義する。フロートを開くたびに呼ぶので、
---`ColorScheme` を監視する必要がない
function M.define()
  local dark = vim.o.background == "dark"
  local base = first_color({ "Normal" }, "bg") or (dark and FALLBACK.bg_dark or FALLBACK.bg_light)
  local text = first_color({ "Normal" }, "fg") or (dark and FALLBACK.fg_dark or FALLBACK.fg_light)
  local add = first_color({ "Added", "DiffAdd", "diffAdded", "String" }, "fg") or FALLBACK.add
  local del = first_color({ "Removed", "DiffDelete", "diffRemoved", "ErrorMsg" }, "fg") or FALLBACK.del

  vim.api.nvim_set_hl(0, "VibingDiffAddLine", { bg = M.blend(add, base, LINE_ALPHA) })
  vim.api.nvim_set_hl(0, "VibingDiffAddText", { bg = M.blend(add, base, TEXT_ALPHA) })
  vim.api.nvim_set_hl(0, "VibingDiffDelLine", { bg = M.blend(del, base, LINE_ALPHA) })
  vim.api.nvim_set_hl(0, "VibingDiffDelText", { bg = M.blend(del, base, TEXT_ALPHA) })
  vim.api.nvim_set_hl(0, "VibingDiffFiller", { bg = base, fg = M.blend(text, base, FILLER_ALPHA) })

  -- unified専用。`+` / `-` はバッファから落として 'statuscolumn' に出すので、記号そのものは
  -- 薄めずアクセントの色をそのまま使う。ここだけが「何が起きた行か」を示している
  vim.api.nvim_set_hl(0, "VibingDiffAddSign", { fg = add })
  vim.api.nvim_set_hl(0, "VibingDiffDelSign", { fg = del })
  vim.api.nvim_set_hl(0, "VibingDiffGutter", { fg = M.blend(text, base, GUTTER_ALPHA) })
  vim.api.nvim_set_hl(0, "VibingDiffHunk", {
    fg = M.blend(text, base, HUNK_FG_ALPHA),
    bg = M.blend(text, base, HUNK_BG_ALPHA),
  })
end

---@param side "before"|"after"
---@return string
function M.win_highlight(side)
  local line = side == "before" and "VibingDiffDelLine" or "VibingDiffAddLine"
  local changed = side == "before" and "VibingDiffDelText" or "VibingDiffAddText"
  return table.concat({
    "DiffAdd:" .. line,
    "DiffChange:" .. line,
    "DiffText:" .. changed,
    -- Neovim 0.11 が足したインライン用の group。`DiffText` が「この側の変わった文字」なのに対し
    -- `DiffTextAdd` は「この側にしか無い文字」を指す。どちらもその側の色で濃くするのが正しく、
    -- 抜かすとカラースキーム側の色がそのまま出て片方だけ浮く
    "DiffTextAdd:" .. changed,
    "DiffDelete:VibingDiffFiller",
  }, ",")
end

---@param win number
---@param side "before"|"after"
function M.apply(win, side)
  local kept = {}
  for _, entry in ipairs(vim.split(vim.wo[win].winhighlight, ",", { plain = true, trimempty = true })) do
    -- こちらが差し替える4つ以外は、ユーザーやFactoryが置いたものとして残す
    if not entry:match("^Diff") then
      table.insert(kept, entry)
    end
  end
  table.insert(kept, M.win_highlight(side))

  pcall(function()
    vim.wo[win].winhighlight = table.concat(kept, ",")
  end)
end

return M
