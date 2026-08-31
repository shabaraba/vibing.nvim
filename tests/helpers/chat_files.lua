--- Test seam for specs that need chat files on disk.
---
--- Writing a chat fixture means knowing the frontmatter keys a chat is required to carry
--- (`vibing.nvim: true`, a `session_id`) and the shape `Frontmatter.serialize` produces. Four
--- specs had already open-coded that pair; shared rather than pasted so a change to the
--- serializer or the required-key set is repaired once instead of breaking specs independently.
--- @module tests.helpers.chat_files

local M = {}

local Frontmatter = require("vibing.infrastructure.storage.frontmatter")

--- Write a chat file with the given frontmatter merged over the required defaults.
--- @param dir string directory the file goes in (no trailing slash)
--- @param name string file name, e.g. "worker.md"
--- @param frontmatter table? keys to set or override
--- @param body string? body after the frontmatter (defaults to an empty User section)
--- @return string path
function M.write(dir, name, frontmatter, body)
  local path = dir .. "/" .. name

  local data = { ["vibing.nvim"] = true, session_id = "session-" .. name }
  for key, value in pairs(frontmatter or {}) do
    data[key] = value
  end

  local text = Frontmatter.serialize(data, body or "## User\n")
  vim.fn.writefile(vim.split(text, "\n", { plain = true }), path)

  return path
end

--- Parse the frontmatter back out of a chat file.
--- @param path string
--- @return table
function M.read_frontmatter(path)
  return (Frontmatter.parse(table.concat(vim.fn.readfile(path), "\n")))
end

return M
