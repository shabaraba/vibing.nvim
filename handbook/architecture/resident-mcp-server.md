# Resident MCP Server: an Exploration

Status: **exploration, nothing implemented.** What was measured on 2026-11-14 about moving the
bundled MCP server from one stdio process per CLI to an HTTP endpoint, the three shapes that could
take, and what is still unmeasured. Read it before changing how a backend reaches
`vibing-nvim`'s tools.

## Why it came up

Anything that needs to know **which chat** an MCP call came from has to learn it out of band, since
the MCP protocol carries no such field. The bundled server does that with `VIBING_PROCESS_ID`
(`handlers/permission.ts`), and only claude gets it: the server is a child of the CLI and inherits
its whole environment.

The other backends hand the MCP subprocess a short list of variables by name — `env_vars` for codex
(`codex_plugin_config.lua`), `BOUND_VARS` for grok, commandcode and opencode — and that list holds
the RPC port and `VIBING_NVIM_CONTEXT`, not the process id. This is read from the code; whether
codex really drops everything else was not run. The consequence is the one that kept
`nvim_permission_prompt` claude-only: a call that names no process is refused, never guessed
(`rpc/handlers/permission_prompt.lua`).

## The shape today

One Node process per CLI process, speaking stdio to the CLI and TCP to **one** Neovim, bound by
`VIBING_NVIM_RPC_PORT`. Measured on this machine: the server serving this chat is a child of this
chat's `claude`, and another chat has its own. claude receives it through `--plugin-dir`, codex
through per-run `-c mcp_servers.vibing-nvim.*`, commandcode through `session/new`'s `mcpServers`.

## What identity can travel on, per backend

Measured with a throwaway HTTP MCP server that returned the `x-vibing-*` headers of the request it
was called with. The pass condition was a `tools/call` whose headers carried the exact values set in
the CLI's environment (or, for commandcode, in the request).

| Backend (version)          | Configuration                                                                         | Result                                               |
| -------------------------- | ------------------------------------------------------------------------------------- | ---------------------------------------------------- |
| claude 2.1.311             | `--mcp-config`, `type: http`, `headers: {"X-Vibing-Process": "${VIBING_PROCESS_ID}"}` | arrived                                              |
| claude 2.1.311             | the same entry in a plugin's `plugin.json` `mcpServers`                               | arrived                                              |
| codex 0.166.0 `exec`       | `-c mcp_servers.<n>.env_http_headers={X-Vibing-Process="VIBING_PROCESS_ID"}`          | arrived                                              |
| codex 0.166.0 `app-server` | the same, two turns on one thread                                                     | arrived on `initialize`, `tools/list` and both calls |
| commandcode 1.88.5 `acp`   | `session/new` `mcpServers: [{name, url, headers: [{name, value}]}]`                   | arrived                                              |

- claude and codex **read the value from the CLI's own environment**, so the configuration text is
  constant and the argv — the duplex reuse key — does not change per process.
- commandcode takes literal header values in `session/new`, so vibing writes the process id there
  itself. Its `initialize` reply advertises `mcpCapabilities: {http: true, sse: false}`.
- This route would remove the need to copy any environment variable into an MCP subprocess, which
  is what left codex, grok, commandcode and opencode without a process id.
- grok, opencode and pi were not measured.

## Surviving a server that goes away

claude, resident (`--input-format stream-json`), HTTP server **without** `Mcp-Session-Id`:

| Case                                                | Result                                                                                                                                                                                |
| --------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Server stopped, then restarted on the same port     | The turn while it was down got `ECONNREFUSED` from the tool and finished normally. The next turn called it with only `tools/call` — no new `initialize` — and the headers were intact |
| Server down when the CLI started, up one turn later | Init reported `hdr:failed`. The next turn still failed. The turn after that connected, with a full handshake, **while init still said `failed`**                                      |

- A restart is survivable only while the server holds no session state. A server that issued
  session ids would lose them across a restart; that was not measured.
- A server that is not answering when the CLI starts leaves its tools missing for at least one
  turn, and the recovery is not tied to anything observable. The server must be ready **before**
  the CLI is spawned. The init status is not a reliable signal either way.
- claude opens with `POST server/discover` (a method the MCP spec does not define; an error reply is
  accepted) and then a `GET` for a server-sent-event stream (a `405` is accepted). A real server
  must tolerate both.
- codex was not run against a server that is down.

## Three shapes

**A. One resident process for the whole machine.** One server for every Neovim, picking the Neovim
by an `X-Vibing-Port` header; `rpc.ts` already keeps one socket per port. The cost is lifecycle:
nobody owns starting and stopping it, a plugin update leaves an old one running, and a loopback HTTP
port needs Origin and Host checks and a credential against other local callers.

**B. One per Neovim, started by that Neovim.** Its lifetime is the editor's, so the "ready before the
CLI is spawned" requirement is met by construction, and the URL is passed to each CLI through the
environment (`"url": "${VIBING_MCP_URL}"`). The port changes on every restart, but the CLIs it
served die with it. This removes the per-session Node start that #859 worked to shorten.
It does collide with one invariant (below).

**C. Neovim speaks MCP over HTTP itself.** No Node layer and no TCP hop. Tool schemas are defined in
TypeScript with zod today, so this is a rewrite, and nothing measured here argues for it.

B is the natural target if this is done at all.

## What would have to be decided

- **The session token is deliberately not an environment variable** (`architecture.md` → "Communication
  Flow"). An HTTP endpoint needs a credential the CLI can send, and the CLI can only get one through
  its environment or its config. A `Bash` call can read both, as it can read the `0600` token file
  today, so the exposure is not new, but the stated rule no longer describes it.
- **Keep the server stateless** (no `Mcp-Session-Id`), so a restart costs one failed call.
- **Tool names keep their form.** A plugin HTTP server surfaced as
  `mcp__plugin_<plugin>_<server>__<tool>`, the same shape the stdio entry has.
- **A backend without HTTP MCP and headers keeps stdio.** The two have to coexist, which is the cost
  of any of A, B and C.
- commandcode asked for `session/request_permission` on an MCP tool call even with `--yolo`. It is
  answered by the existing native-approval route, but that route was not run against this tool.

## Not measured

grok, opencode and pi over HTTP; codex with the server down; a server that issues session ids across
a restart; shape A's routing between several Neovim instances; the per-session start cost saved,
against a stdio server measured the same way.

## How it was measured

Two throwaway scripts, not committed: a dependency-free HTTP MCP server on `127.0.0.1` that answers
`initialize`, `tools/list` and `tools/call` and logs the `x-vibing-*` headers of every request,
driving a real CLI with a prompt asking it to call the tool once. They spent real tokens (claude on
`haiku`). If this work proceeds they belong in `tests/perf/` with the other real-CLI measurements,
split into a shared server module and per-backend drivers — each was over 300 lines as written.
