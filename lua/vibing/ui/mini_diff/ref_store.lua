---@class Vibing.UI.MiniDiff.RefStore
---`gd` が差した参照テキストを保持し、mini.diffに張り付ける。
---
---mini.diffの参照テキストはバッファのキャッシュにしか無く、disableで消える。そして `:edit` は
---バッファwatcherの `on_detach` を呼ぶので、**ファイルを開き直すだけでdisable → 再enableが
---起きる**。したがって「そのターン前の内容」を覚えているのはここしかない。sourceのattachが
---再enableのたびにここから張り直すことで、表示が持続する。
local M = {}

---@type table<number, string[]>
local refs = {}

-- バッファが消えたら追跡もやめる。怠ると、Neovimがバッファ番号を再利用した時に
-- `:VibingDiffClear` が無関係な別バッファへ `diff.disable` / `minidiff_config` クリアをかける
-- （`completion_notifier.lua` の `BufDelete`/`BufWipeout` と同じパターン）
local cleanup_group = vim.api.nvim_create_augroup("VibingMiniDiffCleanup", { clear = true })
vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
  group = cleanup_group,
  callback = function(event)
    refs[event.buf] = nil
  end,
})

---@param buf number
function M.remove(buf)
  refs[buf] = nil
end

---@return number[]
function M.buffers()
  return vim.tbl_keys(refs)
end

---@param diff table mini.diffモジュール
---@param buf number
local function show_overlay(diff, buf)
  -- overlayは削除行を仮想テキストで見せる。ターンで消えた行はファイル上に残っていないので、
  -- これが無いと「何が消えたか」が分からない
  local data = diff.get_buf_data(buf)
  if data and not data.overlay then
    pcall(diff.toggle_overlay, buf)
  end
end

---mini.diffのsource。`gen_source.none()` と違い、再enableのたびに参照テキストを戻す。
---@param diff table mini.diffモジュール
---@return table
local function ref_source(diff)
  return {
    name = "vibing",
    attach = function(buf)
      if not refs[buf] then
        -- `:VibingDiffClear` 後の再enable。sourceを外すのはclear側の仕事なので、
        -- ここは「差すものが無い」とだけ答える
        return false
      end
      diff.set_ref_text(buf, refs[buf])
      -- overlayのトグルはenable()がattachを呼び終えてからでないと、同じ更新で打ち消される
      vim.schedule(function()
        if vim.api.nvim_buf_is_valid(buf) and refs[buf] then
          show_overlay(diff, buf)
        end
      end)
    end,
  }
end

---参照テキストを差す
---@param diff table mini.diffモジュール
---@param buf number
---@param before string[] 空テーブルは「その時点では存在しなかった」＝全体が追加
---@return boolean attached
function M.attach(diff, buf, before)
  refs[buf] = before

  -- 一度disableしてから設定する。sourceのattachは **enable時にしか起きない** ので、既に
  -- enable済みのバッファに `minidiff_config` を書いても効かない。
  --
  -- これを怠ると、既定のgit sourceがattachしたままになり、次に `.git/index` が動いた時点で
  -- ターンの参照テキストが黙ってgit indexの内容に置き換わる。
  pcall(diff.disable, buf)

  local buf_config = vim.b[buf].minidiff_config or {}
  buf_config.source = ref_source(diff)
  vim.b[buf].minidiff_config = buf_config

  -- `set_ref_text` を直接呼ばず、必ずsource経由で張る。直接呼ぶと今回だけは映るが、
  -- 再enableで復元されない状態が残り、`:edit` 一発で消える
  diff.enable(buf)

  -- `vim.b.minidiff_disable` などでmini.diffが降りたケース。黙って何も出さずに成功を
  -- 返すと、呼び出し側のフォールバックまで潰れる
  if not diff.get_buf_data(buf) then
    refs[buf] = nil
    return false
  end

  show_overlay(diff, buf)
  return true
end

return M
