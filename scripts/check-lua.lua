-- Compile Lua with Neovim's parser without executing it.
-- Usage: nvim --headless -u NONE -i NONE -l scripts/check-lua.lua [file ...]
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
local files = {}
if arg and #arg > 0 then
  files = arg
else
  files = vim.fn.globpath(root .. "/lua", "**/*.lua", false, true)
end

if #files == 0 then
  io.stderr:write("No Lua files found under " .. root .. "/lua\n")
  os.exit(1)
end

local failed = false
for _, path in ipairs(files) do
  local chunk, err = loadfile(path)
  if not chunk then
    io.stderr:write(tostring(err) .. "\n")
    failed = true
  end
end
if failed then
  os.exit(1)
end
print(string.format("Lua syntax OK: %d files", #files))
