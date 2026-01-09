-- Final test for complete session persistence
-- This should work after Neovim restart

local FinalSession = {}

function FinalSession.test()
  print("Final session persistence test")
  return {
    status = "working",
    saved_hashes = "stored",
    git_blob = "persisted",
  }
end

return FinalSession
