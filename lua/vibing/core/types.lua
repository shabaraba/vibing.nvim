---@class Vibing.Types
---共通型定義モジュール

---@class Vibing.Message
---@field role "user"|"assistant"|"system"
---@field content string
---@field timestamp string?

---@class Vibing.Session
---@field id string?
---@field created_at string
---@field updated_at string?
---@field mode string?
---@field model string?

---@class Vibing.ContextItem
---@field type "file"|"selection"|"buffer"
---@field path string?
---@field content string
---@field start_line number?
---@field end_line number?
---@field bufnr number?

---@class Vibing.InlineAction
---@field name string
---@field prompt string
---@field tools string[]
---@field use_output_buffer boolean

---@class Vibing.Task
---@field id string
---@field execute fun(done: fun())
---@field cancel fun()?

---@class Vibing.PermissionRule
---@field tools string[]
---@field paths string[]?
---@field commands string[]?
---@field patterns string[]?
---@field domains string[]?
---@field action "allow"|"deny"
---@field message string?

---@class Vibing.PermissionConfig
---@field mode "default"|"acceptEdits"|"bypassPermissions"
---@field allow string[]?
---@field deny string[]?
---@field ask string[]?
---@field rules Vibing.PermissionRule[]?

---@class Vibing.AdapterOpts
---@field streaming boolean?
---@field action_type "chat"|"inline"?
---@field mode string?
---@field model string?
---@field tools string[]?
---@field permissions_allow string[]?
---@field permissions_deny string[]?
---@field permissions_ask string[]?
---@field permission_mode string?
---@field on_tool_use fun(tool: string, file_path: string?)?
---@field _session_id string?
---@field _session_id_explicit boolean?

---@class Vibing.AdapterResponse
---@field content string?
---@field error string?
---@field _handle_id string?

---@class Vibing.WindowConfig
---@field position "current"|"right"|"left"|"float"
---@field width number
---@field border string?

---@class Vibing.ChatConfig
---@field window Vibing.WindowConfig
---@field auto_context boolean
---@field save_location_type "project"|"user"|"custom"
---@field save_dir string?
---@field context_position "prepend"|"append"

return {}
