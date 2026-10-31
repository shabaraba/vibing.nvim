--- Resolves the directory the hook scripts and Neovim exchange request/response files through.
---
--- Single source of truth for what used to be a `/tmp/vibing-hook-<port>` string literal repeated
--- in permission.lua, rate_limit.lua and hook_cleanup.lua. `bin/hooks/*.sh` read the same
--- `$VIBING_HOOK_COMM_DIR` override, and the adapters spawn the CLI with `vim.fn.environ()`, so
--- both sides always agree.
---
--- @module vibing.infrastructure.rpc.comm_dir

local uv = vim.loop
local bit = require("bit")

local M = {}

M.ENV_VAR = "VIBING_HOOK_COMM_DIR"

--- Base directory containing every per-port comm directory.
M.ROOT = "/tmp"

--- Prefix of a comm directory's basename.
M.PREFIX = "vibing-hook-"

--- Basename of the session credential. Mode 0600, inside the directory `ensure_private` creates.
M.TOKEN_NAME = "token"

local DIR_MODE = tonumber("0700", 8)
local FILE_MODE = tonumber("0600", 8)

--- Permission bits, without the file-type bits `fs_stat` packs into the high half.
--- @param mode number
--- @return number
local function permission_bits(mode)
  return mode % 4096
end

--- Open flags for a new private file that must not follow a symlink at the final path.
---
--- Linux and macOS number these differently. Using the wrong `O_NOFOLLOW` is a different open
--- mode, so an unknown platform falls back to `"w"`, which does follow a final symlink.
--- @return integer|string
local function private_open_flags()
  local sys = (uv.os_uname() or {}).sysname
  if sys == "Linux" then
    -- O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW | O_CLOEXEC
    return bit.bor(1, 64, 512, 131072, 524288)
  end
  if sys == "Darwin" then
    -- O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW | O_CLOEXEC
    return bit.bor(0x1, 0x200, 0x400, 0x100, 0x1000000)
  end
  return "w"
end

--- Path of the comm directory a given RPC port would use.
--- @param port number|string
--- @return string
function M.for_port(port)
  return M.ROOT .. "/" .. M.PREFIX .. tostring(port)
end

--- Path of the comm directory for this Neovim instance.
---
--- The key — the RPC port, or the pid when there is no port, so two portless instances cannot share
--- a directory — is `rpc/instance_key.lua`. It moved there when the generated hook settings needed
--- the same distinction for the same reason.
--- @return string
function M.path()
  local override = vim.env[M.ENV_VAR]
  if override and override ~= "" then
    return override
  end

  return M.for_port(require("vibing.infrastructure.rpc.instance_key").get())
end

--- 32 bytes from `/dev/urandom`, hex-encoded.
---
--- The alphabet is fixed so a shell client can embed the value in a JSON string without a parser.
--- @return string|nil token
--- @return string|nil err
function M.random_token()
  local fd, open_err = uv.fs_open("/dev/urandom", "r", 438)
  if not fd then
    return nil, tostring(open_err)
  end
  local data, read_err = uv.fs_read(fd, 32)
  uv.fs_close(fd)
  if type(data) ~= "string" or #data ~= 32 then
    return nil, tostring(read_err or "short read")
  end
  local hex = {}
  for i = 1, #data do
    hex[i] = string.format("%02x", data:byte(i))
  end
  return table.concat(hex)
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
  local uid = uv.getuid and uv.getuid()
  if uid and st.uid ~= uid then
    return nil, "not owned by this user"
  end
  return st
end

--- Create `path` as a private directory, or tighten one this user already owns.
---
--- Refuses a symlink rather than following it. `/tmp` is writable by everyone, so a directory
--- created with the process umask (usually 0755) is searchable by every other account on the host.
--- @param path string
--- @return boolean ok
--- @return string|nil err
function M.ensure_private(path)
  local st = uv.fs_lstat(path)
  if st and st.type == "link" then
    return false, "symlink"
  end
  if st and st.type ~= "directory" then
    return false, "not a directory"
  end
  if not st then
    local ok, err = uv.fs_mkdir(path, DIR_MODE)
    if not ok then
      -- Lost a race with another creator. Only a real directory we own is acceptable.
      local created = owned_directory(path)
      if not created then
        return false, tostring(err)
      end
    end
  end

  local owned, why = owned_directory(path)
  if not owned then
    return false, why
  end
  local chmod_ok, chmod_err = uv.fs_chmod(path, DIR_MODE)
  if not chmod_ok then
    return false, tostring(chmod_err)
  end
  owned, why = owned_directory(path)
  if not owned or permission_bits(owned.mode) ~= DIR_MODE then
    return false, why or "mode"
  end
  return true
end

--- Write `contents` as a mode-0600 regular file, replacing anything already at `path`.
---
--- `io.open` creates the file at 0666 masked by the process umask, and both 022 and 000 leave it
--- world-readable. The mode passed to `fs_open` can only lose bits to the umask, and 0600 has none
--- of the bits a umask removes. `O_NOFOLLOW` keeps a symlink planted at `path` from receiving the bytes.
--- @param path string
--- @param contents string
--- @return boolean ok
--- @return string|nil err
function M.write_private(path, contents)
  local fd, open_err = uv.fs_open(path, private_open_flags(), FILE_MODE)
  if not fd then
    return false, tostring(open_err)
  end
  local written, write_err = uv.fs_write(fd, contents, 0)
  uv.fs_close(fd)
  if written ~= #contents then
    pcall(uv.fs_unlink, path)
    return false, tostring(write_err or "short write")
  end
  local chmod_ok, chmod_err = uv.fs_chmod(path, FILE_MODE)
  if not chmod_ok then
    pcall(uv.fs_unlink, path)
    return false, tostring(chmod_err)
  end
  local st = uv.fs_lstat(path)
  if not st or st.type ~= "file" or permission_bits(st.mode) ~= FILE_MODE then
    pcall(uv.fs_unlink, path)
    return false, "not a private regular file"
  end
  return true
end

--- Make `dir` private and store `token` in it.
---
--- Also tightens files already there: a directory left behind by an older session is mode 0755
--- with mode 0644 request files, and chmod on the directory does not change the files.
--- @param dir string
--- @param token string
--- @return boolean ok
--- @return string|nil err
function M.install_token(dir, token)
  local ok, err = M.ensure_private(dir)
  if not ok then
    return false, err
  end

  local handle = uv.fs_scandir(dir)
  if handle then
    while true do
      local name, typ = uv.fs_scandir_next(handle)
      if not name then
        break
      end
      if typ == "file" then
        uv.fs_chmod(dir .. "/" .. name, FILE_MODE)
      end
    end
  end

  return M.write_private(dir .. "/" .. M.TOKEN_NAME, token)
end

return M
