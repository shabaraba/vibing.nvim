--- What a lightweight utility call runs under on the Grok backend.
---
--- Split out of `grok_command_builder` because the restriction stopped being a list of flags: it
--- is flags, a scratch working directory and a set of environment overrides, and the builder owns
--- only the first of the three. The measurements behind each one are in
--- `handbook/architecture/lightweight-calls.md`.
--- @module vibing.infrastructure.adapter.modules.grok_lightweight

local fs = require("vibing.core.utils.fs")

local M = {}

--- The tool allowlist a lightweight utility call runs under.
---
--- Grok's `--tools` is an allowlist ("only the listed tools will be available; all others are
--- removed"), but it **fails open** on anything it cannot map to a real tool id. Verified against
--- grok 0.2.101 via `--debug-file`: `--tools "none"` logs
--- `tools allowlist had unmappable entries; keeping full grok toolset` and leaves every tool in
--- place, and `--tools ""` is ignored outright — the advertised tool count is unchanged from a
--- plain run either way. So the copilot trick of naming nothing is exactly wrong here; the list
--- has to name a tool grok actually has.
---
--- `todo_write` is that tool. Of grok's built-ins (`run_terminal_cmd`, `grep`, `read_file`,
--- `search_replace`, `list_dir`, `web_search`, `web_fetch`, `todo_write`, `task`) it is the only
--- one that touches no file, no shell and no network — it writes an in-session todo list and
--- nothing else. With it the run logs `tools allowlist applied allowed=["todo_write"]` and the
--- toolset drops from 26 to 3 (the tool plus grok's two always-on MCP meta-tools).
local LIGHTWEIGHT_TOOLS = "todo_write"

--- Deny rule covering every MCP tool, in the `MCPTool(server__tool)` form grok's permission
--- rules require -- an `mcp__server__tool` pattern never matches.
---
--- Needed because `--tools` filters grok's *built-in* tools only; the tools its MCP servers
--- expose are added on top regardless, and grok offers no per-run way to turn those servers off.
--- The allowlist cannot reach them, so execution is denied instead. This is weaker than claude's
--- empty `--mcp-config`, which stops them being offered at all.
---
--- Not redundant with the `dontAsk` mode below, which is the tempting reading. grok's own docs
--- say `dontAsk` stops short of auto-denying while always-approve is on, and grok imports the
--- user's `settings.json` permission rules -- so an allow rule there could pre-approve an MCP
--- tool. An explicit deny is what survives both: grok evaluates `deny` > `ask` > `allow`,
--- "regardless of order or source".
---
--- Both halves of that were measured against grok 0.2.101 rather than trusted to the docs:
---
--- 1. The rule *form* is recognised. Loading it from a `.grok/config.toml` moves
---    `grok inspect`'s permission count from 1 to 2, while an invented kind
---    (`TotallyBogusKind(*)`) leaves it at 1 -- and is reported as "0 skipped", so an
---    unrecognised rule vanishes without a word. A wildcard that silently did nothing would look
---    exactly like one that worked.
--- 2. The rule is *enforced*, through this flag, against a real MCP call. Same prompt and flags
---    twice, `--deny` the only difference: without it the model reports the tool called
---    successfully; with it, "denied by a permission policy", and the debug log records
---    `deny rule matched (enforced before YOLO) tool="mcp:vibing-nvim__nvim_list_instances"`.
---    Both runs passed `--always-approve`, so "enforced before YOLO" is also the precedence
---    claim above, confirmed rather than assumed.
local LIGHTWEIGHT_MCP_DENY = "MCPTool(*)"

--- The `[compat.<vendor>]` cells a lightweight call turns off, as environment variables.
---
--- These are what #588 was filed for the absence of. The cells were known — and rejected — as
--- `config.toml` keys, because editing the user's persistent config to fence one utility call
--- would change their ordinary chats too. What was missed is that **every cell also has an
--- environment variable**, resolved ahead of `config.toml`, and the environment is
--- per-invocation. `grok_cli` hands these to `vim.system` for the lightweight call only.
---
--- **`mcps` is deliberately absent.** `GROK_CLAUDE_MCPS_ENABLED=0` makes `grok inspect` mark
--- every server `[disabled]` and changes nothing about the run — same handshakes, same advertised
--- tool count. Setting it would read as closing the second gap in #588 while closing nothing,
--- which is the `-c mcp_servers={}` mistake of #574 in a new costume; `LIGHTWEIGHT_MCP_DENY`
--- above remains the only thing standing between a utility call and the user's MCP servers.
--- `[compat.codex]` has only a `sessions` cell, the rest being "reserved and currently inert" per
--- grok's own docs, so no `GROK_CODEX_*` variable is set.
---
--- The measurements: `handbook/architecture/lightweight-calls.md` → "What #588 turned out to be".
local COMPAT_ENV = {
  GROK_CLAUDE_RULES_ENABLED = "0",
  GROK_CLAUDE_AGENTS_ENABLED = "0",
  GROK_CLAUDE_SKILLS_ENABLED = "0",
  GROK_CLAUDE_HOOKS_ENABLED = "0",
  GROK_CURSOR_RULES_ENABLED = "0",
  GROK_CURSOR_AGENTS_ENABLED = "0",
  GROK_CURSOR_SKILLS_ENABLED = "0",
  GROK_CURSOR_HOOKS_ENABLED = "0",
}

--- Two features a utility call has no business reaching, both documented env toggles.
---
--- `GROK_MEMORY=0` is the cross-session memory grok can otherwise fold into the conversation —
--- the same "context the user did not ask for" that the project instructions are. `GROK_SUBAGENTS=0`
--- is the second fence under `--tools`: the `task` tool is already outside the allowlist, but the
--- allowlist is the one restriction here known to fail open, and a subagent inherits none of it.
local FEATURE_ENV = {
  GROK_MEMORY = "0",
  GROK_SUBAGENTS = "0",
}

--- Where a lightweight call is run from.
---
--- Grok discovers project instructions by walking from the git root down to the working
--- directory, and project hooks at `<cwd>/.grok/hooks/`. Neither has a per-invocation off switch
--- — but `--cwd` decides what "the project" is, and an empty directory outside any repository is
--- a project with nothing in it. Together with `COMPAT_ENV` this is what takes the injected
--- instruction count to zero: each of the two removes exactly what the other leaves.
---
--- `stdpath("cache")` rather than a fresh `mktemp` directory because grok keys its session store
--- by working directory (`~/.grok/sessions/<url-encoded cwd>/`): a new directory per call would
--- leave one session directory per title generated. It is not under `.vibing/` for the obvious
--- reason — that is inside the repository being fenced out.
---
--- Resuming across working directories is safe, which is what makes this usable on the
--- `/summarize` path: grok answers `Session <id> found locally (originally in <dir>)` and
--- continues, rather than failing the lookup.
local SCRATCH_SUBDIR = "/vibing/grok-lightweight"

local scratch_dir_cache = nil
local scratch_dir_failed = false

--- The scratch directory, created on first use.
---
--- Returns nil rather than raising when it cannot be created: the caller then falls back to the
--- ordinary working directory, which is the pre-#588 behaviour. A title generation that dies
--- because a cache directory was unwritable would be a worse trade than one that reads a
--- CLAUDE.md it did not need.
--- @return string|nil
function M.scratch_dir()
  if scratch_dir_cache then
    return scratch_dir_cache
  end
  if scratch_dir_failed then
    return nil
  end

  local path = vim.fn.stdpath("cache") .. SCRATCH_SUBDIR
  local ok, err = pcall(fs.ensure_dir, path)
  if not ok then
    scratch_dir_failed = true
    vim.notify(
      string.format(
        "[vibing:grok] Could not create the lightweight scratch directory (%s); "
          .. "utility calls will read this project's instructions: %s",
        path,
        tostring(err)
      ),
      vim.log.levels.WARN
    )
    return nil
  end

  scratch_dir_cache = path
  return scratch_dir_cache
end

--- The working directory a grok run uses, for both the `--cwd` flag and the spawned process.
---
--- One definition rather than two, because the flag and the process cwd disagreeing is a bug with
--- no symptom: grok resolves discovery from the flag, so the run would look fenced while the
--- process sat in the project.
--- @param opts Vibing.AdapterOpts
--- @return string|nil
function M.resolve_cwd(opts)
  if not opts.lightweight then
    return opts.cwd
  end
  return M.scratch_dir() or opts.cwd
end

--- Append the flags a lightweight utility call (title generation, /summarize, daily summary) runs
--- under, in place of the chat's permission mode.
---
--- Takes no `opts` on purpose: "the utility call does not inherit the chat's permission mode,
--- `bypassPermissions` included" is then enforced by the signature rather than by a comment. The
--- user put the *chat* in that mode, and a title generated behind their back is not the call they
--- made.
--- @param cmd string[]
function M.append_flags(cmd)
  table.insert(cmd, "--tools")
  table.insert(cmd, LIGHTWEIGHT_TOOLS)
  table.insert(cmd, "--deny")
  table.insert(cmd, LIGHTWEIGHT_MCP_DENY)
  -- codex's `approval_policy="never"`, in grok's vocabulary. grok_cli registers no hook for a
  -- lightweight call, so a mode that prompts would stall on an approval nothing can answer.
  table.insert(cmd, "--permission-mode")
  table.insert(cmd, "dontAsk")
end

--- Write the lightweight environment overrides into the environment table the caller will spawn
--- with. In place, so the single `vim.fn.environ()` copy the adapter already holds stays the one
--- description of the child's environment.
--- @param env table<string, string>
--- @return table<string, string> env
function M.apply_env(env)
  for key, value in pairs(COMPAT_ENV) do
    env[key] = value
  end
  for key, value in pairs(FEATURE_ENV) do
    env[key] = value
  end
  return env
end

--- Forget the resolved scratch directory. Test seam only: the cache is process-wide, so a spec
--- that stubs `stdpath` has to clear what an earlier one resolved.
function M._reset_scratch_cache()
  scratch_dir_cache = nil
  scratch_dir_failed = false
end

return M
