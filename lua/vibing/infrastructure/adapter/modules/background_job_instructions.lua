--- The one rule for where a process belongs: the current turn, a Neovim-owned job, or nowhere.
---
--- Every backend gets these lines, on whichever channel it has (Claude's system prompt, Codex's
--- `developer_instructions`, Grok's `--rules`, OpenCode's instruction file, or the prompt prefix
--- the remaining CLIs only have). `tool` is false where the transport never registers the bundled
--- MCP server (Copilot, Pi, and the oneshot half of Grok and Command Code): a prompt naming a
--- vibing.nvim tool the CLI cannot invoke is the failure `handbook/ADAPTER_DEVELOPMENT.md` forbids.
---
--- The lines carry no per-chat value, so a backend that keeps them in a cached prefix stays
--- byte-stable across turns (#469).
--- @module vibing.infrastructure.adapter.modules.background_job_instructions

local M = {}

--- Present verbatim in both variants: the conformance suite asserts every backend carries it.
M.MARKER = "vibing.nvim's rule for long-running processes"

--- The policy lines for one request.
--- @param tool boolean whether this transport registers the bundled MCP server
--- @return string[]
function M.lines(tool)
  local lines = {
    M.MARKER .. ": a command that belongs to this turn (a test, a build, a one-off check) runs in "
      .. "the foreground and is waited on.",
    "A process that must still be running after this turn ends -- a development server, a file "
      .. "watcher, a `--watch` test runner, a log tailer, a queue worker -- is a background job, "
      .. "not a turn step.",
    tool and "For such a process you MUST use the vibing-nvim nvim_job_start MCP tool. It is owned by "
      .. "Neovim, survives the turn, and reports its completion in this chat; manage it with "
      .. "nvim_job_status, nvim_job_wait and nvim_job_stop. nvim_job_start follows the same "
      .. "permission rules as Bash."
      or "This session exposes no Neovim-owned job tool, so do not start such a process at all.",
    "Do not use shell backgrounding such as &, nohup, setsid or disown for such a process, and do "
      .. "not register it with the CLI's own background-task or monitor mechanism. That registry "
      .. "lives inside the CLI process, which vibing.nvim replaces between turns and reclaims "
      .. "after an idle period, so the registration is lost and the process is usually killed "
      .. "with it.",
    tool and "If nvim_job_start is unavailable, say so instead of silently substituting either mechanism."
      or "Say so and stop instead of substituting either mechanism.",
  }
  return lines
end

--- The same lines rendered as a prompt prefix, for a CLI with no instruction channel.
--- @param prompt string
--- @param tool boolean
--- @return string
function M.prefix(prompt, tool)
  return table.concat(M.lines(tool), "\n") .. "\n\n" .. prompt
end

return M
