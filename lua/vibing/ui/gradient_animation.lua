---@class Vibing.GradientAnimation
---グラデーションアニメーション管理
---AI応答中に行番号を虹色グラデーションでアニメーションさせ、実行状態を視覚的にフィードバック
local M = {}

---@type table<number, { timer: table, ns_id: number, original_hl: table }>
local active_animations = {}

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

---Restore original line number highlight
---@param bufnr number Buffer number
---@param ns_id number Namespace ID
---@param original_hl table Original highlight settings
local function restore_original_highlight(bufnr, ns_id, original_hl)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  -- Clear extmarks
  vim.api.nvim_buf_clear_namespace(bufnr, ns_id, 0, -1)

  -- Restore original highlights if they were customized
  -- Note: We don't need to explicitly restore since clearing extmarks
  -- will make Neovim use the default LineNr highlight again
end

---Start gradient animation for a buffer
---@param bufnr number Buffer number to animate
---@param start_color? string Start color (default: from config)
---@param end_color? string End color (default: from config)
---@param interval? number Animation interval in ms (default: from config)
function M.start(bufnr, start_color, end_color, interval)
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

  -- Use config colors if not specified
  start_color = start_color or config.ui.gradient.colors[1]
  end_color = end_color or config.ui.gradient.colors[2]
  interval = interval or config.ui.gradient.interval

  -- Generate gradient colors
  local gradient_colors = generate_gradient(start_color, end_color, 30)

  -- Create namespace for this buffer
  local ns_id = vim.api.nvim_create_namespace("vibing_gradient_" .. bufnr)

  -- Save original highlight
  local original_hl = save_original_highlight(bufnr)

  -- Create highlight groups for each color
  for i, color in ipairs(gradient_colors) do
    vim.api.nvim_set_hl(0, "VibingGradient" .. bufnr .. "_" .. i, { fg = color, bg = "NONE" })
  end

  -- Show line numbers
  local win = vim.fn.bufwinid(bufnr)
  if win ~= -1 then
    vim.api.nvim_win_set_option(win, "number", true)
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

      local line_count = vim.api.nvim_buf_line_count(bufnr)
      vim.api.nvim_buf_clear_namespace(bufnr, ns_id, 0, -1)

      for line = 1, line_count do
        local color_idx = ((line - 1 + offset) % #gradient_colors) + 1
        local hl_group = "VibingGradient" .. bufnr .. "_" .. color_idx

        vim.api.nvim_buf_set_extmark(bufnr, ns_id, line - 1, 0, {
          number_hl_group = hl_group,
        })
      end

      offset = offset + 1
    end)
  )

  -- Store animation state
  active_animations[bufnr] = {
    timer = timer,
    ns_id = ns_id,
    original_hl = original_hl,
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

  -- Restore original highlight
  restore_original_highlight(bufnr, animation.ns_id, animation.original_hl)

  -- Remove from active animations
  active_animations[bufnr] = nil
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
