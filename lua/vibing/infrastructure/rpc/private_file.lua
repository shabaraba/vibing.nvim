--- Owner-only directories and files under a world-writable root such as `/tmp`.
---
--- Used for the comm directory and everything in it: the session token, `.res` decisions.
--- @module vibing.infrastructure.rpc.private_file

local uv = vim.loop

local M = {}

M.DIR_MODE = tonumber("0700", 8)
M.FILE_MODE = tonumber("0600", 8)

--- Permission bits, without the file-type bits `fs_stat` packs into the high half.
--- @param mode number
--- @return number
local function permission_bits(mode)
  return mode % 4096
end

--- @param path string
--- @return table|nil stat lstat of a directory owned by this user
--- @return string|nil why
local function owned_directory(path)
  local st = uv.fs_lstat(path)
  if not st then
    return nil, "missing"
  end
  if st.type == "link" then
    return nil, "symlink"
  end
  if st.type ~= "directory" then
    return nil, "not a directory"
  end
  if st.uid ~= uv.getuid() then
    return nil, "not owned by this user"
  end
  return st
end

--- Create `path` as a mode-0700 directory, or tighten one this user already owns.
---
--- Refuses a symlink, and a directory another account created first, rather than writing into it.
--- @param path string
--- @return boolean ok
--- @return string|nil err
function M.ensure_dir(path)
  local st = uv.fs_lstat(path)
  if not st then
    -- A lost race with another creator is fine as long as what won is ours; checked below.
    uv.fs_mkdir(path, M.DIR_MODE)
  end

  local owned, why = owned_directory(path)
  if not owned then
    return false, why
  end
  local chmod_ok, chmod_err = uv.fs_chmod(path, M.DIR_MODE)
  if not chmod_ok then
    return false, tostring(chmod_err)
  end
  owned, why = owned_directory(path)
  if not owned or permission_bits(owned.mode) ~= M.DIR_MODE then
    return false, why or "mode"
  end
  return true
end

--- Write `contents` as a new mode-0600 regular file at `path`, replacing whatever entry is there.
---
--- The old entry is unlinked (a symlink is removed, not followed) and the file is created with
--- `O_CREAT | O_EXCL`, which POSIX defines to fail on any existing path, symlinks included. That
--- holds on every platform, unlike an `O_NOFOLLOW` value, which luv does not expose and which
--- Linux numbers differently per architecture. `fchmod` on the open descriptor removes whatever
--- the process umask did to the mode.
--- @param path string
--- @param contents string
--- @return boolean ok
--- @return string|nil err
function M.write(path, contents)
  uv.fs_unlink(path)
  local fd, open_err = uv.fs_open(path, "wx", M.FILE_MODE)
  if not fd then
    return false, tostring(open_err)
  end
  local chmod_ok, chmod_err = uv.fs_fchmod(fd, M.FILE_MODE)
  local written, write_err = uv.fs_write(fd, contents, 0)
  uv.fs_close(fd)
  if not chmod_ok or written ~= #contents then
    uv.fs_unlink(path)
    return false, tostring(chmod_err or write_err or "short write")
  end
  return true
end

return M
