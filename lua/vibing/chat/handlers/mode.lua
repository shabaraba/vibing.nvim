---/mode コマンドハンドラー
---@param args string[]
---@param chat_buffer Vibing.ChatBuffer
---@return boolean success
return function(args, chat_buffer)
  if #args == 0 then
    vim.notify("[vibing] Usage: /mode <mode>", vim.log.levels.WARN)
    return false
  end

  local mode = args[1]
  local valid_modes = { "auto", "plan", "code" }
  local is_valid = false

  for _, valid_mode in ipairs(valid_modes) do
    if mode == valid_mode then
      is_valid = true
      break
    end
  end

  if not is_valid then
    vim.notify(
      "[vibing] Invalid mode: " .. mode .. " (valid: auto, plan, code)",
      vim.log.levels.ERROR
    )
    return false
  end

  if not chat_buffer then
    vim.notify("[vibing] No chat buffer", vim.log.levels.ERROR)
    return false
  end

  local success = chat_buffer:update_frontmatter("mode", mode)
  if not success then
    vim.notify("[vibing] Failed to update frontmatter", vim.log.levels.ERROR)
    return false
  end

  vim.notify("[vibing] Mode set to: " .. mode, vim.log.levels.INFO)
  return true
end
