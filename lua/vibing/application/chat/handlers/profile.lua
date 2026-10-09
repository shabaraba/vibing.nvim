local notify = require("vibing.core.utils.notify")
local Profiles = require("vibing.core.constants.profiles")

---`/profile <name>`: what `profile:` frontmatter says, and the way a chat created as a worker is
---taken back into ordinary use (and vice versa). Nothing else moves — the session, the transcript
---and the orchestration links stay — so the conversation carries on where it was.
---@param args string[]
---@param chat_buffer Vibing.ChatBuffer
---@return boolean
return function(args, chat_buffer)
  local config = require("vibing.config").get()
  local names = Profiles.names(config)

  if #args == 0 then
    notify.warn("/profile <" .. table.concat(names, "|") .. ">", "Usage")
    return false
  end

  local profile = args[1]

  if not Profiles.is_valid(profile, config) then
    notify.error(string.format("Invalid profile: %s (valid: %s)", profile, table.concat(names, ", ")))
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

  -- Say what actually follows, because the CLI decides it: tools and setting sources widen from
  -- the next message, but the instruction block was recorded at the chat's first message
  -- (`core/constants/profiles.lua`).
  notify.info(
    string.format(
      "Profile set to: %s (tools and project settings apply from the next message; "
        .. "the instruction block stays as the chat started)",
      profile
    )
  )
  return true
end
