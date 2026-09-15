# Stream fixtures

One directory per backend id (`claude/`, `codex/`, `copilot/`, `grok/`), each file a real capture
of that CLI's stdout for one turn, one JSON line per line, exactly as the CLI wrote it. The
conformance suite (`tests/lua/infrastructure/adapter/conformance/stream_fixtures_spec.lua`) replays
every file here through the backend's decoder and the shared renderer and asserts the contracts of
ADR 009 that a stream can violate: a session id is learned, text reaches the chat, and a tool call
that starts also ends.

Captures, not hand-written shapes. The decoders were written against payloads read off the real
CLIs (`handbook/architecture/cli-integration.md` says which version each was), and a fixture is
how that reading is kept from drifting. The trimmed shapes used by `renderer_parity_spec.lua` are
derived from these; when a CLI changes its stream, the capture here is what shows it.

| File                               | CLI    | Version | What it exercises                                          |
| ---------------------------------- | ------ | ------- | ---------------------------------------------------------- |
| `claude/subagent_forwarding.jsonl` | claude | 2.1.x   | `--forward-subagent-text`: subagent text under a Task tool |

Adding a backend means adding a directory here with at least one ordinary turn (text plus one
tool call) captured from the CLI, with the version recorded in this table. A directory that does
not exist is reported by the suite as a gap, not skipped silently.
