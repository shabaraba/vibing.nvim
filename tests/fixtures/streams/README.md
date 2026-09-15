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

| File                               | CLI     | Version | What it exercises                                          |
| ---------------------------------- | ------- | ------- | ---------------------------------------------------------- |
| `claude/subagent_forwarding.jsonl` | claude  | 2.1.x   | `--forward-subagent-text`: subagent text under a Task tool |
| `codex/read_note_turn.jsonl`       | codex   | 0.154.0 | `command_execution` start/end pair, `agent_message` text   |
| `copilot/read_note_turn.jsonl`     | copilot | 1.0.80  | `tool.execution_start`/`_complete` paired by `toolCallId`  |
| `grok/text_turn.jsonl`             | grok    | 0.2.101 | thought/text deltas and the `end` event carrying sessionId |

Grok's capture has **no tool event and that is the point**: the turn did call a tool, and grok's
headless stream still carried only `thought`, `text` and `end`. That is what
`decoders/grok_streaming_json.lua` says, and this file is the evidence for it.

Adding a backend means adding a directory here with at least one ordinary turn (text plus one
tool call, where the CLI reports its tool calls at all) captured from the CLI, with the version
recorded in this table. A directory that does not exist is reported by the suite as a gap, not
skipped silently.

## Taking a capture

Build the argv from the descriptor rather than by hand, so the capture is of the command
vibing.nvim really spawns:

```bash
mkdir -p /tmp/capture && printf 'The answer is 42.\n' > /tmp/capture/note.txt

VIBING_BACKEND=codex \
VIBING_PROMPT='Read the file note.txt in the current directory and reply with the number it contains.' \
VIBING_CWD=/tmp/capture \
VIBING_PERMISSION_MODE=bypassPermissions \
VIBING_OUT=/tmp/capture/argv.json \
  nvim --headless -u tests/minimal_init.lua -l tests/fixtures/streams/capture_argv.lua

# then run that argv from /tmp/capture with stdin closed, keeping stdout verbatim
```

Three things the recipe is shaped by. The prompt is **read-only** because the argv carries
whatever `bypassPermissions` means on that CLI, and a capture is not worth a write outside the
scratch directory. No hook argument is passed, so nothing waits on a permission decision no
Neovim is listening for. Stdin is closed, because a CLI given no prompt argument otherwise waits
on a terminal that is not there (this is what `descriptor.stdin = ""` handles in a real turn).

Then strip what is local to the machine that captured it — a home directory in a skills or
MCP-server listing is environment, not stream shape — and record the CLI version in the table
above.
