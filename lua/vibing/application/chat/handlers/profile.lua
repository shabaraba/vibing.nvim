local notify = require("vibing.core.utils.notify")
local Profiles = require("vibing.core.constants.profiles")

---`/profile <default|worker>`: what `profile:` frontmatter says, and the way a chat created as a
---worker is taken back into ordinary use (and vice versa). Nothing else moves — the session, the
---transcript and the orchestration links stay — so the conversation carries on where it was.
---@param args string[]
---@param chat_buffer Vibing.ChatBuffer
---@return boolean
return function(args, chat_buffer)
  if #args == 0 then
    notify.warn("/profile <" .. table.concat(Profiles.VALUES, "|") .. ">", "Usage")
    return false
  end

  local profile = args[1]

  if not Profiles.is_valid(profile) then
    notify.error(string.format("Invalid profile: %s (valid: %s)", profile, table.concat(Profiles.VALUES, ", ")))
    return false
  end

  if not chat_buffer then
    notify.error("No chat buffer")
    return false
  end

  local success = chat_buffer:update_frontmatter("profile", profile)
  if not success then
    notify.error("Failed to update frontmatter")
    return false
  end

  -- The system prompt changes with it, so the next request re-writes the cached prefix once.
  notify.info(string.format("Profile set to: %s (takes effect from the next message)", profile))
  return true
end
