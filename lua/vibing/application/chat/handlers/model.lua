local notify = require("vibing.core.utils.notify")

---@param args string[]
---@param chat_buffer Vibing.ChatBuffer
---@return boolean
return function(args, chat_buffer)
  if #args == 0 then
    notify.warn("/model <model>", "Usage")
    return false
  end

  local model = args[1]
  if model == "" then
    notify.warn("/model <model>", "Usage")
    return false
  end

  local known = require("vibing.infrastructure.adapter.models.catalog").all_values()
  local codex_default = model == "default"
    and chat_buffer
    and chat_buffer.parse_frontmatter
    and require("vibing.core.constants.modes").resolve_agent(
      chat_buffer:parse_frontmatter(),
      require("vibing.config").get()
    ) == "codex"
  if codex_default then
    table.insert(known, 1, "default")
  end
  if not vim.tbl_contains(known, model) then
    notify.error(string.format("Invalid model: %s (valid: %s)", model, table.concat(known, ", ")))
    return false
  end

  if not chat_buffer then
    notify.error("No chat buffer")
    return false
  end

  local success = chat_buffer:update_frontmatter("model", model)
  if not success then
    notify.error("Failed to update frontmatter")
    return false
  end

  notify.info(string.format("Model set to: %s", model))
  return true
end
