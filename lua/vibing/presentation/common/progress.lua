---@class Vibing.Presentation.Progress
---処理する対象を木のまま並べて右下に出しっぱなしにし、終わったら自分で消える進捗表示。
---
---**メインループ上から呼ぶ前提**。CLIの完了ハンドラは `stream_handler` が `vim.schedule` 済み
---なので、内側で重ねてはいけない。重ねると描画だけが後ろにずれ、表示と実際の進み具合が食い違う。
---
---置き方の計算（罫線・幅・行数・枠の設定）は `progress_layout.lua`。ここはその結果をウィンドウに
---貼る操作と、バッファ・ウィンドウ・タイマーの生き死にだけ。
---通知ではなくこれを出す理由は `handbook/architecture/chat-lineage.md` →「Showing the Walk」。
local M = {}

local Factory = require("vibing.infrastructure.ui.factory")
local Layout = require("vibing.presentation.common.progress_layout")

---完了表示を残す時間。すぐ閉じると「終わった」を読む間がない
local DEFAULT_LINGER_MS = 2000
---取りかかった1件が決着しないまま経ったら、進行を知らせる側が死んだとみなして畳む時間。
---1件あたりCLI呼び出し1〜2回ぶんの余裕は要るので、待ちきれる長さに取る
local DEFAULT_STALL_MS = 10 * 60 * 1000

---@class Vibing.Progress.Item
---@field label string 表示名
---@field depth integer? 根を0とする深さ（省略は0＝木にせず並べる）

---@class Vibing.Progress.Handle
---@field package _buf number?
---@field package _win number?
---@field package _timer number?
---@field package _title string
---@field package _items Vibing.Progress.Item[]
---@field package _prefixes string[]
---@field package _status table<integer, "ok"|"fail"> 決着の付いた行だけが載る。nil が未着手
---@field package _running integer?
---@field package _message string?
---@field package _width integer
---@field package _height integer
---@field package _linger_ms integer
---@field package _stall_ms integer
---@field package _touched_at integer 最後に進んだ時刻（`vim.uv.now`）
---@field package _configured string? 最後に貼った枠の設定（同じなら貼り直さない）
local Handle = {}
Handle.__index = Handle

---決着の付いた件数。`_status` から数えるので、同じ行を2度 `mark` しても二重に数えない
---@return integer
function Handle:_settled()
  return #vim.tbl_keys(self._status)
end

---@return table
function Handle:_win_config()
  return Layout.window({
    width = self._width,
    -- 完了の1行は木に上書きせず足す。上書きすると最後の1件だけ結果が読めないまま消える
    rows = self._height + (self._message and 1 or 0),
    title = self._title,
    settled = self:_settled(),
    total = #self._items,
  })
end

function Handle:_draw()
  if not self._buf or not vim.api.nvim_buf_is_valid(self._buf) then
    return
  end

  -- 端末の大きさは走行中に変わる。開いたときの寸法のまま描き続けると、狭くなった画面では
  -- 枠が画面からはみ出す（`nvim_win_set_config` はそれを拒む）。広がった側は `relabel` が
  -- 伸ばすので、ここは収める側だけ見る
  self._width = Layout.fit_width(self._width)
  self._height = Layout.height(#self._items)

  local lines = Layout.lines({
    items = self._items,
    prefixes = self._prefixes,
    status = self._status,
    running = self._running,
    height = self._height,
    width = self._width,
    message = self._message,
  })

  vim.bo[self._buf].modifiable = true
  vim.api.nvim_buf_set_lines(self._buf, 0, -1, false, lines)
  vim.bo[self._buf].modifiable = false

  self:_reconfigure()
end

---枠（大きさ・位置・タイトルの件数）を必要になったときだけ貼り直す
---
---スピナーは毎秒8回描くが、そのとき変わるのは行の中身だけ。設定まで毎回渡すと、同じ内容の
---タイトルを毎回 virt-text に組み直させたうえで再描画の下限を上げ続ける
function Handle:_reconfigure()
  -- ウィンドウが無いのは、ユーザーが `:only` などで閉じたということ。開き直さない。
  -- 進捗はこの操作の付属物で、閉じる指示を上書きしてまで出すものではない
  if not self._win or not vim.api.nvim_win_is_valid(self._win) then
    return
  end
  local config = self:_win_config()
  local signature = table.concat({ config.width, config.height, config.row, config.col, config.title }, ":")
  if signature == self._configured then
    return
  end
  self._configured = signature
  vim.api.nvim_win_set_config(self._win, config)
end

function Handle:_stop_spinner()
  if self._timer then
    vim.fn.timer_stop(self._timer)
    self._timer = nil
  end
end

---1件に取りかかったことを表示する
---@param index integer 何件目か（1始まり）
function Handle:start(index)
  self._running = index
  self._touched_at = vim.uv.now()
  self:_stop_spinner()
  self._timer = vim.fn.timer_start(Layout.SPIN_MS, function()
    -- バッファが消えたのにタイマーだけ回り続けるのを防ぐ。`close` を経ない終わり方
    -- （ウィンドウごと wipe された）でもここで止まる
    if not self._buf or not vim.api.nvim_buf_is_valid(self._buf) then
      return self:_stop_spinner()
    end
    -- 進行を知らせる側が死んでも、こちらは死んだことを知らされない。呼び出し側の逐次実行は
    -- コールバックの鎖で、その途中の例外は通知に落とされて鎖がそこで止まる（`finish` は来ない）。
    -- 何も起きない時間が続いたら、回りっぱなしの箱を残さずに畳む
    if vim.uv.now() - self._touched_at > self._stall_ms then
      return self:close()
    end
    self:_draw()
  end, { ["repeat"] = -1 })
  self:_draw()
end

---1件の表示名を差し替える（改名したチャットが、木の上でも新しい名前になる）
---@param index integer
---@param label string
function Handle:relabel(index, label)
  self._items[index].label = label
  -- 広げはするが縮めない。1件ごとに枠が踊ると、肝心の中身が読みづらくなる
  self._width = Layout.fit_width(math.max(self._width, Layout.width(self._items, self._prefixes)))
  self:_draw()
end

---1件の結果を確定する
---@param index integer
---@param ok boolean
function Handle:mark(index, ok)
  self._status[index] = ok and "ok" or "fail"
  if self._running == index then
    self._running = nil
    self:_stop_spinner()
  end
  self:_draw()
end

---完了を表示し、読める間だけ置いてから自分で閉じる
---@param message string 木の下に足す文言
function Handle:finish(message)
  self._running = nil
  self:_stop_spinner()
  self._message = message
  self:_draw()
  vim.defer_fn(function()
    self:close()
  end, self._linger_ms)
end

---閉じる（何度呼んでもよい）
function Handle:close()
  self:_stop_spinner()
  Factory.close_window(self._win)
  Factory.delete_buffer(self._buf)
  self._win, self._buf = nil, nil
end

---@param opts {title: string, items: Vibing.Progress.Item[], linger_ms: integer?, stall_ms: integer?}
---@return Vibing.Progress.Handle
function M.open(opts)
  local prefixes = Layout.prefixes(opts.items)
  local handle = setmetatable({
    _title = opts.title,
    _items = opts.items,
    _prefixes = prefixes,
    _status = {},
    _width = Layout.width(opts.items, prefixes),
    _height = Layout.height(#opts.items),
    _linger_ms = opts.linger_ms or DEFAULT_LINGER_MS,
    _stall_ms = opts.stall_ms or DEFAULT_STALL_MS,
    _touched_at = vim.uv.now(),
  }, Handle)

  handle._buf = Factory.create_buffer({ buftype = "nofile", bufhidden = "wipe", modifiable = false })
  -- `Factory.create_float` を使わないのは、この箱の設定が生きている間に変わるから
  -- （タイトルの件数、動いている行を見せるための高さと位置）。開くのも更新も同じ設定を通す
  handle._win = vim.api.nvim_open_win(handle._buf, false, handle:_win_config())
  handle:_draw()
  return handle
end

return M
