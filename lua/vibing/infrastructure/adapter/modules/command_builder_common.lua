--- The parts of argv construction that do not depend on which CLI is being launched.
---
--- Four command builders carried their own copy of each of these. They were byte-identical or
--- trivially reworded, which is the worst kind of duplication: nothing signals when one of them
--- is fixed and the other three are not. #537 was exactly that -- `resolve_model` was corrected
--- on one backend and stayed broken on two others.
---
--- What stays per-backend is everything that encodes a CLI's own vocabulary: flag names, sandbox
--- and permission mapping, session/resume syntax, and where in the argv the prompt goes.
---
--- @module vibing.infrastructure.adapter.modules.command_builder_common

local M = {}

--- The language the response should be written in, or nil to leave it to the CLI.
---
--- `config.language` is accepted both as a plain string and as a table with `default`/`chat`,
--- which is why this is not a one-line lookup.
---
--- @param opts Vibing.AdapterOpts
--- @param config Vibing.Config
--- @return string|nil
function M.resolve_language(opts, config)
  local language = opts.language
  if not language and config.language then
    if type(config.language) == "table" then
      language = config.language.default or config.language.chat
    else
      language = config.language
    end
  end
  return type(language) == "string" and language or nil
end

--- The one-line instruction that pins the response language, or nil when none applies.
---
--- Returns nil for English (the CLIs' own default) and for a code with no display name, so the
--- caller never has to repeat those two guards. Where the sentence goes is the caller's business:
--- claude and grok put it at the top of the system prompt, codex and copilot prepend it to the
--- user prompt, because those two take no system prompt.
---
--- @param opts Vibing.AdapterOpts
--- @param config Vibing.Config
--- @return string|nil
function M.language_instruction(opts, config)
  local language = M.resolve_language(opts, config)
  if not language or language == "en" then
    return nil
  end

  local names = require("vibing.core.utils.language").language_names
  local name = names[language]
  if not name then
    return nil
  end

  return string.format("Always respond in %s (%s).", name, language)
end

--- The `@file:` context entries rendered as a prompt prefix, or "" when there are none.
---
--- Trailing blank line included, so callers can concatenate unconditionally.
---
--- @param opts Vibing.AdapterOpts
--- @return string
function M.context_prefix(opts)
  local parts = {}
  for _, ctx in ipairs(opts.context or {}) do
    if ctx:match("^@file:") then
      table.insert(parts, string.format("Context file: %s", ctx:sub(7)))
    end
  end

  if #parts == 0 then
    return ""
  end
  return table.concat(parts, "\n") .. "\n\n"
end

--- A cached `exepath` lookup for one CLI binary.
---
--- The cache is process-wide and deliberately so -- `exepath` is not free and PATH does not move
--- under a running Neovim. `reset()` is the test seam: a spec that wants the "CLI missing" path
--- has to clear what an earlier spec resolved.
---
--- @param binary string name to look up on PATH
--- @param missing_message string raised when it is not there
--- @return table `{ resolve = fun(): string, reset = fun() }`
function M.binary_resolver(binary, missing_message)
  local cached = nil

  return {
    --- @return string path
    resolve = function()
      if not cached then
        local found = vim.fn.exepath(binary)
        if found == "" then
          error(missing_message)
        end
        cached = found
      end
      return cached
    end,

    reset = function()
      cached = nil
    end,
  }
end

return M
