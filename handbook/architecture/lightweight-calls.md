# Lightweight Calls

Detail behind `.claude/rules/architecture.md` → "Session Persistence". Title generation,
`/summarize`, `:VibingSummarize` and the daily summary run as `lightweight` calls.
`core/types.lua` states the obligation each adapter owes — no tools, no project config, no hooks,
`utility_model` — rather than the mechanism any one of them uses, because the four CLIs differ in
kind rather than in degree. This file is each backend's mechanism, and what happens when the CLI
silently stops honouring it.

**Lightweight calls are restricted differently per backend, because the CLIs differ in kind.**
Claude removes the tools outright with `--tools ""`. Codex cannot: probing its config schema with
`--strict-config` (which rejects unknown fields) against codex 0.147 shows `tools.shell`,
`tools.apply_patch`, `tools.view_image`, `tools.plan_tool` and `tools.mcp` are all unknown fields,
and `tools.web_search` is the only tool toggle that exists. So `codex_command_builder` fences the
call in instead — `sandbox_mode="read-only"`, `tools.web_search=false`, `approval_policy="never"`,
`project_doc_max_bytes=0`, plus the flags `--ignore-user-config --strict-config` — and
`codex_cli.lua` skips hook registration, matching `claude_cli.lua`. `project_doc_max_bytes=0` and
`--ignore-user-config` are codex's answers to claude's `--setting-sources ""` and
`--strict-mcp-config`/`--mcp-config`: without them a utility call still read `AGENTS.md` and still
reached the user's MCP servers. `--strict-config` is not a fence of its own — it is what keeps the
others from lapsing unnoticed.

**`-c mcp_servers={}` used to stand in for that and did nothing**, which is what #574 was about.
`-c` _deep-merges_ into `config.toml`, so an empty table adds no keys and removes none: measured
against codex 0.147, `codex mcp list -c 'mcp_servers={}'` still lists every configured server, and
under `codex exec` a server whose command touches a file was still launched and still wrote it.
That last part makes it a boundary rather than a preference — codex spawns MCP servers itself, so
the process runs **outside** the read-only sandbox. No narrower switch exists (`mcp.enabled`,
`tools.mcp`, `features.mcp`, `mcp_enabled`, `disable_mcp` are all unknown fields; `mcp_servers=false`
is a type error), and per-server `mcp_servers.<name>.enabled=false` works but needs a name list
that goes stale the moment a server is added — silently, which is the failure mode being fixed.
`--ignore-user-config` is therefore accepted along with its known cost: it also drops
`model_provider`, so a user on a custom provider gets utility calls against the default OpenAI
endpoint. Auth is unaffected; codex reads it from `CODEX_HOME` either way.

`--ignore-user-config` does **not** cover `project_doc_max_bytes`. `AGENTS.md` is discovered from
the cwd, not from `config.toml`, so dropping the user config only restores the key's 32768-byte
default. Verified with `codex debug prompt-input`, which renders the model-visible prompt without
calling the model: a marker line in `AGENTS.md` is present without the override and absent with it.

**`--strict-config` is what stops the rest of that list from lapsing in silence.** Codex ignores
unknown `-c` keys, so the day it renames or drops one, the fence would come off with no error and
no warning — and unlike the degradation `rate_limit.lua` tolerates, what is lost here is a safety
boundary whose absence is unobservable. With the flag, the utility call fails loudly instead. It is
only safe **paired with `--ignore-user-config`**: on its own it also strictifies the user's
`config.toml`, so one unrecognised field of their own would break every title generation — which is
what made #571 reject the flag. With the user config unread it validates our overrides and nothing
else. Both flags have existed since at least codex 0.140 and are accepted on `codex exec resume`
too, so unlike `-s` neither is lost on the `/summarize` path.

`read-only` blocks writes **and** network, verified by running commands under `codex sandbox`
rather than read off the docs: a write reports `Operation not permitted` and `curl` returns
`000` where the same request outside the sandbox returns `200`. That matters because the shell
tool itself cannot be removed, so the sandbox is the only thing closing the exfiltration path
a prompt injection in the summarized transcript would otherwise have.

Three details there are not interchangeable. The restrictions are `-c` overrides rather than the
`-s` flag because `/summarize` passes a session id and `codex exec resume` does not accept `-s`. The
restriction ignores `permission_mode` entirely, `bypassPermissions` included: the user put the
_chat_ in that mode, and a title generated behind their back is not the call they made. And
`utility_model` still goes through the Claude-name filter, so its `sonnet` default becomes no
`-m` at all rather than a model codex would reject.

**Copilot can remove the tools outright, and does it in one flag.** `--available-tools` is the
filter deciding "which tools the model can see" (`copilot help permissions`), so a list naming
nothing leaves nothing. Measured against copilot 1.0.78 by counting tool schemas in
`--log-level debug` output: an ordinary run offers 62 tools, `--available-tools=view` offers 1,
and `--available-tools=__vibing_no_tools__` offers 0 — with the turn still completing normally
(`toolRequests: []`, exit 0). That count includes the user's MCP tools, so the one flag also
covers what claude needs `--strict-mcp-config` for; the MCP servers are still spawned, but expose
nothing. `--no-custom-instructions` is the `--setting-sources ""` half, verified by planting a
sentinel string in `AGENTS.md` and watching it reach the prompt twice without the flag and not at
all with it. Nothing to skip on the hook side: `copilot_cli` registers none at all.

The sentinel has to be a name, not an empty string. `--available-tools=` parses as an empty list
and copilot ignores it, leaving all 62 tools — so the flag reads as working while doing nothing.

**Grok fails open on exactly that trick, which is why it does the opposite.** Its `--tools` is an
allowlist, but an entry it cannot map to a real tool id makes it discard the whole restriction:
`--debug-file` on grok 0.2.101 records
`tools allowlist had unmappable entries; keeping full grok toolset` for `--tools "none"`, and
`--tools ""` is ignored the same way copilot's empty list is. So `grok_command_builder` names a
real tool — `todo_write`, the only built-in reaching no file, shell or network — and the run logs
`tools allowlist applied` with the toolset down from 26 to 3. `--permission-mode dontAsk` stands
in for codex's `approval_policy="never"`.

**Skipping the hook does not mean grok has no hook**, and that difference bites. Claude and codex
register one per invocation (`--settings <path>`, `-c hooks.pre_tool_use=…`), so omitting the flag
genuinely leaves the run hookless. Grok discovers `<cwd>/.grok/hooks/` instead, which
`GrokSettingsGenerator.ensure` writes once per cwd and nothing ever removes — so `grok_cli`
skipping `ensure` for a lightweight call only skips _rewriting_ it. Any project that has had one
ordinary grok chat still has the hook on disk, and a utility call is by definition something that
happens after a chat.

**Copilot does not have grok's problem**, despite also writing its hook into the project tree. The
generated plugin under `<cwd>/.vibing/copilot-plugin/` is reachable only through `--plugin-dir`,
which the lightweight branch never emits — copilot auto-discovers hooks from `~/.copilot/hooks/`,
`.github/hooks/`, its policy dirs and `settings.json`, and vibing.nvim writes none of those. So a
leftover plugin from an earlier chat is inert, and skipping generation really does leave the run
hookless, the way it does for claude and codex.

That is why `todo_write` had to be added to `grok_tool_vocabulary`. It is claude's `TodoWrite`
under another name; unmapped, the raw name reached `can_use_tool`, missed the `INTERNAL_TOOLS`
always-allow list, matched nothing in the default allow list and resolved to `ask` — which
`cancel_and_deny` serves by killing the CLI process _before_ checking for an approval UI. A
lightweight call registers none, so a title generation would have died silently on the one tool
its own allowlist leaves it. Deleting the hook file instead was rejected: the cwd is shared with
every concurrent chat, which still needs it.

**Grok is the one backend that cannot keep the whole `lightweight` bargain,** and that is a
property of its CLI rather than something left undone here. `--tools` filters built-ins only —
MCP tools are added on top regardless (the advertised count stays ~254 higher either way) and
grok 0.2.101 has no per-run flag to disable MCP servers, so the builder can only deny their
_execution_ with `--deny "MCPTool(*)"`, in the `MCPTool(server__tool)` form grok's rules require.

That wildcard is measured, not assumed, because a rule grok does not recognise is dropped in
silence — `grok inspect`'s permission count goes 1 → 2 for `MCPTool(*)` loaded from a
`.grok/config.toml` but stays at 1 for an invented kind, which it still reports as "0 skipped".
Enforcement was then checked through the flag itself against a real MCP call: same prompt, same
flags, `--deny` the only difference. Without it the model reports the tool called successfully;
with it, "denied by a permission policy", and the debug log records
`deny rule matched (enforced before YOLO) tool="mcp:vibing-nvim__nvim_list_instances"`. Both runs
passed `--always-approve`, so "before YOLO" is where the `deny` > `ask` > `allow` precedence gets
confirmed too — which is what makes this not redundant with `dontAsk`.
Project instructions have no escape hatch at all: grok reads `AGENTS.md`/`CLAUDE.md` from the repo
and the home directory, and the only switches (`[compat.claude]`, `[mcp_servers]`) are persistent
config, not per-invocation. `--sandbox read-only` was considered and rejected — grok's own docs
say its network blocking is a no-op on macOS, and resuming a session under a sandbox profile is
constrained, which `/summarize` always is.

The model half of that lives in `modules/non_claude_model.lua`, shared by codex, copilot and grok.
It was three byte-identical private copies before, and #537 was filed against codex alone — so
teaching one copy about `lightweight` would have left the same bug live on the other two, with
nothing marking them stale. The restriction half stays per-backend on purpose: claude _removes_
tools with `--tools ""`, codex can only fence them, and no shared vocabulary spans that.
`core/types.lua` states the obligation each adapter owes for `lightweight` — no tools, no project
config, no hooks, `utility_model` — rather than the mechanism any one of them uses.

**The `model_provider` that `--ignore-user-config` drops is announced rather than left to be
discovered** (#587). `codex_provider_notice.lua` warns once per Neovim session when the configured
provider is not codex's own `openai` default. `codex_cli.lua` triggers it on `--ignore-user-config`
actually being in the argv it just built, not on `opts.lightweight` alone: the builder documents
that flag as a stand-in for a narrower switch codex does not have yet, so reading the built command
is what makes the warning disarm itself the day the flag stops being used, rather than going on
describing a loss that no longer happens. `lightweight` still guards the scan because the prompt is
the last element of the argv, and a message consisting of exactly that flag would otherwise match.

It warns and does not repair, because codex will hand over the provider's _name_ and not its
_definition_: `codex doctor --json` reports the resolved provider at
`checks["config.load"].details["model provider"]`, but nothing reports the
`[model_providers.<name>]` table — not `doctor`, and not the app-server protocol, whose
`ConfigReadResponse.Config` carries `model_provider` as a bare string and no provider map at all
(`codex app-server generate-json-schema --experimental`). Re-injecting the provider would still
mean hand-parsing `config.toml`, which is why #587's option 2 was not taken.

Asking codex is the whole point: the name comes back **resolved**, by codex's own config loader,
so there is no TOML parsing and none of the false positives (an inactive profile section) or false
negatives (a profile) that kept the warning out of #582. Three properties of the probe are
load-bearing:

- **The exit status says nothing.** `codex doctor --json` exits 1 whenever any check fails, and a
  missing login alone is enough — it exits 1 even on a config that loaded cleanly. Only
  `checks["config.load"].status` answers the question, and stdout is valid JSON either way.
- **The key is `"model provider"`, with a space.** Captured from codex 0.147 into
  `tests/fixtures/codex_doctor.json` rather than read off a schema.
- **Unreadable means silent.** Every parse failure returns nil and nothing is said, because an
  unreliable warning is worse than none — its silence gets read as "you are fine".

It runs on the first lightweight call rather than at `setup()` because `doctor` makes one
reachability request to the active provider's endpoint; it is asynchronous and nothing waits for
it. `agent.codex_provider_notice.enabled` turns the whole thing off, probe included, and is the
one toggle of this shape that **defaults to `true`** — `subagent`, `auto_resume_on_limit` and
`dap` all default to `false` because they spend tokens or run unattended, and this spends none. A
warning about a change the user cannot otherwise see fails at its only job if it is off until
asked for. Absent config reads as enabled, so a hand-built config table does not silently lose it.

The `profile = "x"` config key that #582 named as a false-negative route is moot from codex
0.147, which rejects it outright (`legacy profile = "x" config is no longer supported`); the
surviving route is the `-p/--profile` flag, which vibing.nvim passes to neither `codex exec` nor
the probe, so the two resolve identically.
