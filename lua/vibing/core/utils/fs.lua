--- Filesystem helpers that have to survive concurrent Neovim instances.
--- @module vibing.core.utils.fs

local uv = vim.loop

local M = {}

--- How many times to re-attempt a directory creation that lost a race. Each retry starts the walk
--- again from a path that is strictly further along, so this converges in a couple of rounds; the
--- bound is only there so a genuinely impossible path cannot spin.
local MAX_ATTEMPTS = 5

--- Whether `path` is a directory right now.
--- @param path string
--- @return boolean
local function is_dir(path)
  local stat = uv.fs_stat(path)
  return stat ~= nil and stat.type == "directory"
end

--- Create a directory, treating "someone else created it first" as success.
---
--- `vim.fn.mkdir(path, "p")` is **not atomic**. It walks the path creating each component and
--- raises `E739: Cannot create directory ...: file already exists` when another process creates
--- one of them in between. Measured at 9 failures across 200 concurrent calls.
---
--- That is a routine race here, not a theoretical one. Several vibing.nvim paths are shared
--- between processes: the instance registry is machine-wide, a project's `.vibing/` is shared by
--- every chat open on it, and plenary runs one child Neovim per spec file. It is what made
--- `tests/view_spec.lua` flake in CI (#576).
---
--- **Catching the error and re-checking is not enough**, which is worth stating because it is the
--- obvious fix and it still failed 3 times out of 200. The component that collided is often an
--- *intermediate* one, and the process that won that component has not necessarily reached the
--- leaf yet — so the loser's `fs_stat` on the leaf legitimately finds nothing. Retrying is what
--- resolves it: the next walk starts past the component that collided.
---
--- @param path string
--- @return boolean success the directory exists now
function M.ensure_dir(path)
  for _ = 1, MAX_ATTEMPTS do
    local ok, created = pcall(vim.fn.mkdir, path, "p")
    if ok and created == 1 then
      return true
    end
    if is_dir(path) then
      return true
    end
    if ok then
      -- mkdir declined without raising. Nothing raced us, so another attempt says the same thing.
      break
    end
  end

  return is_dir(path)
end

return M
