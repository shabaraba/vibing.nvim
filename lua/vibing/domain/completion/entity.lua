---Completion domain entities
---@module "vibing.domain.completion.entity"

---@class Vibing.CompletionItem
---@field word string Text to insert
---@field label string Display text
---@field kind "Command"|"Skill"|"File"|"Argument" Item kind
---@field description string? Full description
---@field detail string? Additional detail (e.g., source)
---@field source "builtin"|"project"|"user"|"plugin" Source origin
---@field insertText string? Text to insert (if different from word)
---@field filterText string? Text for filtering (if different from word)

---@class Vibing.TriggerContext
---@field trigger "slash"|"file"|"argument" Trigger type
---@field query string User input after trigger
---@field start_col number Completion start column (1-indexed, as returned by string:find())
---@field command_name string? For argument completion

return {}
