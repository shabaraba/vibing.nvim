--- The credential every RPC request must carry, and the file clients read it from.
---
--- The file is `<comm dir>/token` (`comm_dir.TOKEN_NAME`). It is a file rather than an environment
--- variable because Codex and Grok forward the environment by an explicit list and Grok copies those
--- values into its session request; `handbook/architecture/cli-integration.md`.
--- @module vibing.infrastructure.rpc.session_token

local uv = vim.loop
local CommDir = require("vibing.infrastructure.rpc.comm_dir")
local PrivateFile = require("vibing.infrastructure.rpc.private_file")

local M = {}

local TOKEN_BYTES = 32

--- 32 bytes from `/dev/urandom`, hex-encoded.
---
--- The alphabet is fixed so a shell client can embed the value in a JSON string without a parser.
--- @return string|nil token
--- @return string|nil err
function M.generate()
  local fd, open_err = uv.fs_open("/dev/urandom", "r", 0)
  if not fd then
    return nil, tostring(open_err)
  end
  local data, read_err = uv.fs_read(fd, TOKEN_BYTES)
  uv.fs_close(fd)
  if type(data) ~= "string" or #data ~= TOKEN_BYTES then
    return nil, tostring(read_err or "short read")
  end
  return (data:gsub(".", function(c)
    return string.format("%02x", c:byte())
  end))
end

--- True when `provided` and `expected` are the same non-empty string.
---
--- Walks every byte of the longer input instead of returning at the first mismatch.
--- @param provided any
--- @param expected string|nil
--- @return boolean
function M.matches(provided, expected)
  if type(provided) ~= "string" or type(expected) ~= "string" or expected == "" then
    return false
  end
  local mismatch = #provided == #expected and 0 or 1
  for i = 1, math.max(#provided, #expected) do
    if (provided:byte(i) or 0) ~= (expected:byte(i) or 0) then
      mismatch = 1
    end
  end
  return mismatch == 0
end

--- Make `dir` private and store `token` in it, replacing a previous session's token atomically.
---
--- Also tightens files already there: a directory left behind by an older session is mode 0755
--- with mode 0644 request files, and chmod on the directory does not change the files.
--- @param dir string
--- @param token string
--- @return boolean ok
--- @return string|nil err
function M.install(dir, token)
  local ok, err = PrivateFile.ensure_dir(dir)
  if not ok then
    return false, err
  end

  local handle = uv.fs_scandir(dir)
  while handle do
    local name, typ = uv.fs_scandir_next(handle)
    if not name then
      break
    end
    if typ == "file" then
      uv.fs_chmod(dir .. "/" .. name, PrivateFile.FILE_MODE)
    end
  end

  local path = dir .. "/" .. CommDir.TOKEN_NAME
  local tmp = path .. ".tmp"
  ok, err = PrivateFile.write(tmp, token)
  if not ok then
    return false, err
  end
  local renamed, rename_err = uv.fs_rename(tmp, path)
  if not renamed then
    uv.fs_unlink(tmp)
    return false, tostring(rename_err)
  end
  return true
end

return M
