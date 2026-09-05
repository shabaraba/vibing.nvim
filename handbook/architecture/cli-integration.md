# CLI Integration: the Hook Protocol and Backend Seams

Detail behind `.claude/rules/architecture.md` → "Communication Flow". The rules file states the
flow and the two invariants it imposes (the hook fails closed; a backend name belongs in that
backend's own module). This file is why each is shaped that way — including the measurements
taken against the real CLIs and the alternatives that were rejected.

## The PreToolUse Hook

The PreToolUse hook is synchronous and blocks the tool call: it writes the hook payload to
`/tmp/vibing-hook-<port>/<request_id>.req`, sends a one-line JSON-RPC notification to the RPC port
with `nc`, then polls for `<request_id>.res` (up to 120s). It **fails closed** — if `nc` cannot
connect, or the response never arrives, the hook exits 2 and the tool is denied. `VIBING_HANDLE_ID`
is passed through so concurrent chats don't cross-wire each other's approval UI (see
`active_stream_registry.lua`). The comm directory path comes from
`infrastructure/rpc/comm_dir.lua` (the single source of truth shared by the handlers, the cleanup
routine and `bin/hooks/*.sh`). It is machine-wide shared state keyed by port, so it has two
escape hatches: `$VIBING_HOOK_COMM_DIR` overrides it outright (tests use this), and without a
listening port it falls back to a PID-suffixed path rather than a single shared `vibing-hook-0`.
The instance registry has the same treatment via `$VIBING_INSTANCES_DIR` (honoured by both
`rpc/registry.lua` and `claude-plugin/mcp-server/src/handlers/instances.ts`).

The `.res` file carries **three** decisions, not two, and the difference is the whole permission
contract with the CLI:

- **`deny`** — the hook exits 2 with the reason on stderr, which is how a deny rule's `message`
  reaches the model.
- **`allow`** — the hook prints the JSON verbatim on stdout, and the CLI skips its own permission
  gate. Note that exiting 0 in silence is **not** an approval: the CLI reads it as "no opinion".
- **`defer`** — vibing.nvim permits the call but leaves the CLI's gate, and with it the user's own
  `settings.json` rules, in charge. The hook exits 0 silently.

Only vibing-nvim's own MCP tools get `allow`; everything else vibing.nvim permits gets `defer`.
Granting everything would override the user's `settings.json` deny rules, which
`--setting-sources user,project,local` still pulls in.

Those MCP tools are the exception because `--allowedTools` cannot express them reliably: it takes
literal prefixes, and the plugin-scoped one is `mcp__plugin_<plugin>_<server>__`, built from
`claude-plugin/.claude-plugin/plugin.json`. `can_use_tool.is_vibing_nvim_mcp_tool` matches on the
suffix instead, so the grant survives a rename that `VIBING_NVIM_MCP_TOOL_PATTERNS` would not.
Before #564 every allowed call took the silent path, so under any mode but `bypassPermissions` the
CLI refused those tools while vibing.nvim's own log said "allow".

The match is on the name and nothing else, and that is worth stating plainly because an `allow`
skips the user's own `settings.json` rules. It requires the separator both registration styles put
before the server name (`_vibing-nvim__nvim_<tool>`), so a server merely _ending_ with the name
(`mcp__my-vibing-nvim__…`) does not match. A third-party server genuinely registered as
`vibing-nvim` and exposing `nvim_*` tools **would** be granted — nothing in a tool name says who
registered it. That needs an untrusted MCP server already in the user's own Claude Code config, so
it is accepted rather than solved.

`hook_cleanup.cleanup_stale_dirs()` (run at startup) treats a comm directory as stale only when
its owning Neovim is gone: it cross-checks `registry.list()`, which already filters to live PIDs,
so a concurrent instance's in-flight `.req`/`.res` files are never deleted.

## What the System Prompt May Not Contain

vibing.nvim starts a fresh CLI process for every turn and re-attaches it to the session with
`--resume`. That is the one structural difference from every other way the CLI is run, and it has
a consequence that only shows up on the bill: **anything the CLI computes once at process start
and places in the system prompt is re-computed on every turn.** The system prompt is the first
thing in the prefix, so a value that moves invalidates the cache for it _and_ the whole
conversation behind it — floor plus history, re-written at cache-creation price, which is 12.5× the
read price. A long-lived process pays that once per session; here it is once per change.

`agent.git_instructions` is the case that was found (#681). The CLI embeds a block like

```text
This is the git status at the start of the conversation. ...
Current branch: ...
Status: <git status --short>
Recent commits: <git log --oneline -10>
```

computed once per session id and cached in memory (`refreshReason: "session_start"`). One edit,
one commit or one untracked file changes those bytes. Measured against 2.1.231 on a 128k-token
session, the turn following a one-line edit reports `new=128,456 / read=144,076` with the block on
and `new=9 / read=272,424` with it off — the same input volume, 6.4× the input cost. The
fixed prefix ahead of the block stays cached, so what misses is exactly the conversation, which is
why the loss grows with `context` (`handbook/configuration.md` → "Token Usage").

Read out of the 2.1.231 binary, the gate is:

```js
function () {
  let e = process.env.CLAUDE_CODE_DISABLE_GIT_INSTRUCTIONS
  if (isTruthy(e)) return false
  if (isFalsy(e)) return true
  return settings().includeGitInstructions ?? true
}
// ... and at the call site:
let n = env.CLAUDE_CODE_REMOTE || !includeGitInstructions() ? null : await gitStatus(e)
```

So Claude Code on the web has never carried the block at all — its process is long-lived, and the
block was still judged not worth it. `claude_cli.lua` therefore sets
`CLAUDE_CODE_DISABLE_GIT_INSTRUCTIONS=1` in the child environment by default. Three things about
that shape:

- **The environment, not the `--settings` file.** `includeGitInstructions` is a real settings key,
  but `--settings` is written per cwd by `settings_generator.lua` and is skipped entirely on the
  lightweight path, which would leave title generation and `/summarize` carrying a block that
  changes under them. The environment is the one channel every call goes through.
- **Both settings write the variable**, because the CLI reads it as a tri-state: `"1"` suppresses,
  `"0"` forces on, unset defers to `includeGitInstructions` — which
  `--setting-sources user,project,local` still loads. So `agent.git_instructions = true` writes
  `"0"` rather than nothing; writing nothing would leave the opt-in unable to deliver what it
  promises to a user who has that key set to `false`. Verified against the CLI: `0` and `false`
  both put the block back, `1` removes it.
- **A value already in the environment wins over both.** Setting `CLAUDE_CODE_REMOTE` instead is
  not an option: it changes other behaviour (this repository's own `SessionStart` hook keys on
  it), and a variable that means "you are in a container" is not a variable to lie about.
- **What is lost is small and recoverable.** The model no longer starts a turn knowing the branch,
  the recent commits or the changed files, and the CLI's built-in "match the style of recent
  commits" instruction goes with them. One `git status` or `git log` call buys that back, and one
  tool call is orders of magnitude cheaper than re-writing the prefix. Commit-message conventions
  belong in `.claude/rules/` or `.vibing/system-prompt.md`, where they are part of the stable
  prefix rather than re-derived.

The invariant generalises past this one block: **a per-turn process makes every startup-time
computation a prefix variable.** The CLI version string, the date and the cache-breaker phrase are
the other candidates; none has been measured moving, and #674's re-write detection is what is meant
to catch the next one rather than a hand-maintained list here. vibing.nvim's own
`--append-system-prompt` was byte-stabilised for the same reason in #469.

## Backend Seams

These are the seams that stop backend identity leaking into shared code. The rule they encode:
**a backend name belongs in that backend's own module, and shared code takes what it is handed.**
`bin/hooks/pre-tool-use.sh` is the one deliberate exception, and the last bullet says why.

- **Tool vocabulary.** Backends name their tools differently (codex calls an edit `apply_patch`,
  copilot uses `bash`/`view`/`create`/`edit`/`web_search`, grok `search_replace`/
  `run_terminal_command`). Each adapter owns a `<backend>_tool_vocabulary.lua` and passes it to
  `set_active_opts` as a generic `_tool_vocabulary`; `rpc/handlers/permission.lua` just calls
  `normalize_payload`, `to_canonical` and `normalize_input` when the module offers them. The
  handler contains no backend name.

  The three are separate because backends disagree at three different levels, and the order
  matters — each step feeds the next:
  1. `normalize_payload` — the hook payload's own key names. Claude sends
     `tool_name`/`tool_input`; grok sends `toolName`/`toolInput`. Read straight through, the
     handler sees a nil tool name, so the two steps below get nothing to work on, every rule
     misses, and the turn stalls until the hook fails closed. This must run **first**.
  2. `to_canonical` — the tool's name (`apply_patch` → `Edit`).
  3. `normalize_input` — where the path lives inside the input. Granular `paths` rules read
     `input.file_path`; grok sends `path`/`target_file`/`filePath`.

  All three shapes were captured from the real CLIs, not read off their docs.

- **No MCP on every backend.** Grok registers no `chat_bufnr` and reaches no vibing-nvim MCP
  server, so `grok_command_builder` deliberately keeps `--rules` to the backend-agnostic
  conventions. Naming `nvim_ask_user_question` there would hand the model a tool it cannot call —
  see `features.md` → AskUserQuestion Support. Codex reaches the server since
  `codex_plugin_config` (`plugin-and-commands.md` → "Codex") but still registers no `chat_bufnr`.

- **Grok's hooks need a git repository.** `grok_settings_generator.lua` writes
  `<cwd>/.grok/hooks/` and marks the cwd trusted in `<$GROK_HOME|~/.grok>/trusted_folders.toml`,
  but grok discovers project hooks only inside a git repo (verified with `grok inspect`: the
  `project` entry appears under "Hooks" after `git init` and is absent before). Outside one the
  file is written and never read, which would silently allow every tool, so `ensure()` warns
  once per cwd instead. `$GROK_HOME` is grok's own documented override and is honoured — which is
  also the seam the specs use, since folder trust cascades to subdirectories and never expires.

- **Copilot injects its hook as a plugin.** Copilot has no per-run hook flag, and the two places
  it reads hooks from are both off limits: `~/.copilot/` is the user's own config and
  `.github/hooks/` is their repository. But `copilot --plugin-dir <dir>` loads a plugin for that
  run only, and a plugin may contribute hooks — so `copilot_settings_generator.lua` writes a
  throwaway plugin to `<cwd>/.vibing/copilot-plugin/` and points `--plugin-dir` at it. The hooks
  are inlined in `plugin.json` (one file, no sibling `hooks.json`), which works only as a bare
  event map: the `{"version": 1, "hooks": …}` envelope a standalone hooks file requires is
  silently ignored when inlined — both forms were run against the CLI.
  That is what makes `dynamic_permissions` true for copilot. Unlike grok's, it does **not** need a
  git repository (checked by running copilot in a non-git cwd and reading its own log).

  Three things about copilot's hook contract were captured from copilot 1.0.78 rather than read
  off its docs, and each one silently disables the gate if got wrong:
  1. **Its schema is not Claude's.** The event is lowercase `preToolUse`, the command goes under
     `bash`, and the timeout is `timeoutSec`. A matcher in a camelCase event is compiled as a
     regex, so Claude's `*` is rejected — `~/.copilot/logs` reports "Invalid matcher regex … hook
     will be skipped" and every tool runs unchecked. The generated file omits the matcher.
  2. **It reads a flat decision.** `{"permissionDecision":…}` on stdout; the
     `{"hookSpecificOutput":{…}}` wrapper is ignored, and a nested deny let the tool run. Exit 2
     denies too, but the model is told only "hook exited with code 2" — stderr is dropped, where
     Claude uses it to carry the reason. So `pre-tool-use.sh` takes a `copilot` argument and
     unwraps the response instead of re-encoding it (a reason containing a quote survives).
  3. **A hook timeout fails _open_.** Every non-zero exit fails closed, but a hook that outlives
     `timeoutSec` is ignored and the tool proceeds. The generated `timeoutSec` therefore stays
     well above the ~120s that `pre-tool-use.sh` waits before denying.

  The payload differs too — `toolName` with `toolArgs` as a JSON _string_ — which
  `copilot_tool_vocabulary.normalize_payload` handles, the same seam grok uses. Every name in that
  table except `powershell` and `rg` was read off a real payload; those two come from GitHub's
  hooks reference and are kept because a missing alias lets a deny rule fall open, while a
  never-sent one is inert.

  A subagent's own tool calls reach this hook as well, under their own names (`task` fires, then
  the `bash` the subagent runs) — so the gate covers delegated work, not just the top-level turn.

  **Why the backend name is in the shared script**, against the rule above: what varies is not
  only the JSON shape but the deny _signalling convention_ — Claude denies with exit 2 + stderr,
  copilot with exit 0 + stdout. That is shell semantics, so it lives in the shell. The
  alternatives are worse: a second script would duplicate the ~90 lines that are the security
  half of this one (comm dir, atomic `.req` rename, `nc` fail-closed, the 120s poll, the timeout
  deny), and a fail-closed protocol that exists twice is one that drifts into failing open;
  writing the decision in the backend's own format from `permission.lua` would move process
  control into Lua and force the handler — which deliberately knows no backend name — to pick an
  encoder, including on the fallback deny path where no `active_opts` resolve. Passing no
  argument selects Claude's convention, which is what the other three backends do.

  The gate is skipped in two cases, both by `copilot_cli.lua` rather than the generator:
  `bypassPermissions` (the mode asked for no gate) and `lightweight` (`core/types.lua` obliges
  every adapter to register no hooks for utility calls). And installing it is allowed to fail:
  the generator runs under `pcall`, and a failure warns and falls back to the static
  `--deny-tool` flags rather than taking the turn down.
