---@class Vibing.GradientAnimation
---グラデーションアニメーション管理
---AI応答中に行番号を虹色グラデーションでアニメーションさせ、実行状態を視覚的にフィードバック
---
---ターンが開いたまま人間の答えを待っている間（承認・AskUserQuestion）は、流れるグラデーションを
---止めて単色（`ui.gradient.waiting_color`）に塗り替える。承認も質問もターンを kill せずに待つ
---ようになった（#778, #788）ので、ターン開始〜終了だけを見て回し続けると「こちらの番」が
---「まだ動いている」と区別できなくなる。
local M = {}

---待機中に行番号を塗るハイライトグループ
M.WAITING_HL = "VibingLineNrWaiting"

---@type table<number, { timer: table, ns_id: number, original_hl: table, original_number: boolean, hl_groups: string[], waiting: boolean? }>
local active_animations = {}

---`ui.gradient.waiting_color` の既定値。既定グラデーション（赤〜黄）と色相が重ならない青
M.DEFAULT_WAITING_COLOR = "#3fa9f5"

---Generate gradient colors from start to end and back
---@param start_color string Start color in hex format (e.g. "#cc3300")
---@param end_color string End color in hex format (e.g. "#fffe00")
---@param steps number Number of gradient steps (default: 30)
---@return string[] Array of hex color strings for smooth gradient
local function generate_gradient(start_color, end_color, steps)
  steps = steps or 30

  -- Parse hex colors to RGB
  local function hex_to_rgb(hex)
    hex = hex:gsub("#", "")
    return tonumber(hex:sub(1, 2), 16), tonumber(hex:sub(3, 4), 16), tonumber(hex:sub(5, 6), 16)
  end

  -- Convert RGB to hex
  local function rgb_to_hex(r, g, b)
    return string.format("#%02x%02x%02x", math.floor(r), math.floor(g), math.floor(b))
  end

  local r1, g1, b1 = hex_to_rgb(start_color)
  local r2, g2, b2 = hex_to_rgb(end_color)

  local gradient_forward = {}
  for i = 0, steps - 1 do
    local ratio = i / (steps - 1)
    local r = r1 + (r2 - r1) * ratio
    local g = g1 + (g2 - g1) * ratio
    local b = b1 + (b2 - b1) * ratio
    table.insert(gradient_forward, rgb_to_hex(r, g, b))
  end

  -- Create round-trip gradient (forward + backward, avoiding duplicates)
  local gradient_colors = {}
  for i, color in ipairs(gradient_forward) do
    table.insert(gradient_colors, color)
  end
  for i = #gradient_forward - 1, 2, -1 do
    table.insert(gradient_colors, gradient_forward[i])
  end

  return gradient_colors
end

---Save original line number highlight
---@param bufnr number Buffer number
---@return table Original highlight settings
local function save_original_highlight(bufnr)
  -- Get current line number highlight
  local linenr_hl = vim.api.nvim_get_hl(0, { name = "LineNr" })
  local cursorlinenr_hl = vim.api.nvim_get_hl(0, { name = "CursorLineNr" })

  return {
    LineNr = linenr_hl,
    CursorLineNr = cursorlinenr_hl,
  }
end

---Restore original line number highlight and settings
---@param bufnr number Buffer number
---@param ns_id number Namespace ID
---@param original_hl table Original highlight settings
---@param original_number boolean Original number setting
---@param hl_groups string[] Highlight groups to clear
local function restore_original_highlight(bufnr, ns_id, original_hl, original_number, hl_groups)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  -- Clear extmarks
  vim.api.nvim_buf_clear_namespace(bufnr, ns_id, 0, -1)

  -- Clear created highlight groups
  for _, hl_group in ipairs(hl_groups) do
    pcall(vim.api.nvim_set_hl, 0, hl_group, {})
  end

  -- Restore original number setting
  local win = vim.fn.bufwinid(bufnr)
  if win ~= -1 then
    vim.api.nvim_set_option_value("number", original_number, { win = win })
  end
end

---@class Vibing.GradientAnimationOpts
---@field is_waiting? fun(): boolean ターンが人間の答えを待っているか。tick ごとに問い合わせる

---Start gradient animation for a buffer
---
---待機状態はイベントで受け取らず tick ごとに `is_waiting` へ問い合わせる。承認・質問の出口は
---それぞれ4つずつあり、全部から通知を配線すると1つ漏れた時点で表示が戻らなくなる。
---@param bufnr number Buffer number to animate
---@param opts? Vibing.GradientAnimationOpts
function M.start(bufnr, opts)
  opts = opts or {}
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  -- Stop existing animation if any
  M.stop(bufnr)

  local config = require("vibing.config").get()

  -- Check if gradient animation is enabled
  if not config.ui or not config.ui.gradient or not config.ui.gradient.enabled then
    return
  end

  local start_color = config.ui.gradient.colors[1]
  local end_color = config.ui.gradient.colors[2]
  local interval = config.ui.gradient.interval
  local is_waiting = opts.is_waiting

  -- Generate gradient colors
  local gradient_colors = generate_gradient(start_color, end_color, 30)

  -- Create namespace for this buffer
  local ns_id = vim.api.nvim_create_namespace("vibing_gradient_" .. bufnr)

  -- Save original highlight and number setting
  local original_hl = save_original_highlight(bufnr)
  local win = vim.fn.bufwinid(bufnr)
  local original_number = false
  if win ~= -1 then
    original_number = vim.api.nvim_get_option_value("number", { win = win })
  end

  -- Create highlight groups for each color
  local hl_groups = {}
  for i, color in ipairs(gradient_colors) do
    local hl_group = "VibingGradient" .. bufnr .. "_" .. i
    vim.api.nvim_set_hl(0, hl_group, { fg = color, bg = "NONE" })
    table.insert(hl_groups, hl_group)
  end
  -- 共有グループなので hl_groups には入れない（停止時にクリアすると他チャットの待機表示が消える）
  vim.api.nvim_set_hl(0, M.WAITING_HL, {
    fg = config.ui.gradient.waiting_color or M.DEFAULT_WAITING_COLOR,
    bg = "NONE",
    bold = true,
  })

  -- Show line numbers (only if not already enabled)
  if win ~= -1 and not original_number then
    vim.api.nvim_set_option_value("number", true, { win = win })
  end

  local offset = 0
  local timer = vim.loop.new_timer()

  -- Start animation
  timer:start(
    0,
    interval,
    vim.schedule_wrap(function()
      if not vim.api.nvim_buf_is_valid(bufnr) then
        timer:stop()
        timer:close()
        active_animations[bufnr] = nil
        return
      end

      local waiting = false
      if is_waiting then
        local ok, result = pcall(is_waiting)
        waiting = ok and result == true
      end

      local line_count = vim.api.nvim_buf_line_count(bufnr)
      vim.api.nvim_buf_clear_namespace(bufnr, ns_id, 0, -1)

      for line = 1, line_count do
        local hl_group
        if waiting then
          hl_group = M.WAITING_HL
        else
          local color_idx = ((line - 1 + offset) % #gradient_colors) + 1
          hl_group = "VibingGradient" .. bufnr .. "_" .. color_idx
        end

        vim.api.nvim_buf_set_extmark(bufnr, ns_id, line - 1, 0, {
          number_hl_group = hl_group,
        })
      end

      -- 待機中は流れを止める。再開したとき止まった位置から続く
      if not waiting then
        offset = offset + 1
      end
      local animation = active_animations[bufnr]
      if animation then
        animation.waiting = waiting
      end
    end)
  )

  -- Store animation state
  active_animations[bufnr] = {
    timer = timer,
    ns_id = ns_id,
    original_hl = original_hl,
    original_number = original_number,
    hl_groups = hl_groups,
  }
end

---Stop gradient animation for a buffer
---@param bufnr number Buffer number
function M.stop(bufnr)
  local animation = active_animations[bufnr]
  if not animation then
    return
  end

  -- Stop timer
  if animation.timer then
    animation.timer:stop()
    animation.timer:close()
  end

  -- Restore original highlight and settings
  restore_original_highlight(
    bufnr,
    animation.ns_id,
    animation.original_hl,
    animation.original_number,
    animation.hl_groups
  )

  -- Remove from active animations
  active_animations[bufnr] = nil
end

---Whether the animation is currently showing the waiting-for-human state
---@param bufnr number Buffer number
---@return boolean
function M.is_waiting(bufnr)
  local animation = active_animations[bufnr]
  return animation ~= nil and animation.waiting == true
end

---Check if animation is active for a buffer
---@param bufnr number Buffer number
---@return boolean True if animation is active
function M.is_active(bufnr)
  return active_animations[bufnr] ~= nil
end

---Stop all active animations
function M.stop_all()
  for bufnr, _ in pairs(active_animations) do
    M.stop(bufnr)
  end
end

return M
