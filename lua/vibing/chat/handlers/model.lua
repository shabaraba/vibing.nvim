---/model コマンドハンドラー
---@param args string[]
---@param chat_buffer Vibing.ChatBuffer
---@return boolean success
return function(args, chat_buffer)
  if #args == 0 then
    vim.notify("[vibing] Usage: /model <model>", vim.log.levels.WARN)
    return false
  end

  local model = args[1]
  local valid_models = { "opus", "sonnet", "haiku" }
  local is_valid = false

  for _, valid_model in ipairs(valid_models) do
    if model == valid_model then
      is_valid = true
      break
    end
  end

  if not is_valid then
    vim.notify(
      "[vibing] Invalid model: " .. model .. " (valid: opus, sonnet, haiku)",
      vim.log.levels.ERROR
    )
    return false
  end

  if not chat_buffer then
    vim.notify("[vibing] No chat buffer", vim.log.levels.ERROR)
    return false
  end

  local success = chat_buffer:update_frontmatter("model", model)
  if not success then
    vim.notify("[vibing] Failed to update frontmatter", vim.log.levels.ERROR)
    return false
  end

  vim.notify("[vibing] Model set to: " .. model, vim.log.levels.INFO)
  return true
end
