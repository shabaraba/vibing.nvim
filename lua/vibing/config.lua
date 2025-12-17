---@class Vibing.Config
---@field adapter string
---@field cli_path string
---@field chat Vibing.ChatConfig
---@field inline Vibing.InlineConfig
---@field keymaps Vibing.KeymapConfig
---@field permissions Vibing.PermissionsConfig

---@class Vibing.PermissionsConfig
---@field allow string[]
---@field deny string[]

---@class Vibing.ChatConfig
---@field window Vibing.WindowConfig
---@field auto_context boolean
---@field save_dir string

---@class Vibing.WindowConfig
---@field position "right"|"left"|"float"
---@field width number
---@field border string

---@class Vibing.InlineConfig
---@field default_action "fix"|"feat"|"explain"

---@class Vibing.KeymapConfig
---@field send string
---@field cancel string
---@field add_context string

local M = {}

---@type Vibing.Config
M.defaults = {
  adapter = "agent_sdk",  -- "agent_sdk" (recommended), "claude_acp", or "claude"
  cli_path = "claude",
  chat = {
    window = {
      position = "right",
      width = 0.4,
      border = "rounded",
    },
    auto_context = true,
    save_dir = vim.fn.stdpath("data") .. "/vibing/chats",
  },
  inline = {
    default_action = "fix",
  },
  keymaps = {
    send = "<CR>",
    cancel = "<C-c>",
    add_context = "<C-a>",
  },
  permissions = {
    allow = {
      "Read",
      "Edit",
      "Write",
      "Glob",
      "Grep",
    },
    deny = {
      "Bash",
    },
  },
}

---@type Vibing.Config
M.options = {}

---@param opts? Vibing.Config
function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", {}, M.defaults, opts or {})

  -- Validate tool names in permissions
  local valid_tools = {
    Read = true,
    Edit = true,
    Write = true,
    Bash = true,
    Glob = true,
    Grep = true,
    WebSearch = true,
    WebFetch = true,
  }

  if M.options.permissions then
    for _, tool in ipairs(M.options.permissions.allow or {}) do
      if not valid_tools[tool] then
        vim.notify(
          string.format("[vibing] Unknown tool '%s' in permissions.allow", tool),
          vim.log.levels.WARN
        )
      end
    end
    for _, tool in ipairs(M.options.permissions.deny or {}) do
      if not valid_tools[tool] then
        vim.notify(
          string.format("[vibing] Unknown tool '%s' in permissions.deny", tool),
          vim.log.levels.WARN
        )
      end
    end
  end

  vim.fn.mkdir(M.options.chat.save_dir, "p")
end

---@return Vibing.Config
function M.get()
  return M.options
end

return M
