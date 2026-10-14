# Pi backend

Pi 1.2.0 is the upstream interface this implementation targets; real CLI validation is pending.
Install Pi from <https://pi.dev>, run `./build.sh`,
and choose the backend through `ai.chat.agent` or chat frontmatter `agent: pi`.
Chats default to resident RPC; helpers and subagent chats use oneshot JSON.

```lua
require("vibing").setup({
  ai = {
    chat = { agent = "pi", model = "mlx-community/Qwen3.6-27B-4bit" },
    helpers = { model = "mlx-community/Qwen3.6-27B-4bit" },
    agents = {
      pi = {
        -- path = "/absolute/path/to/pi", -- omit to discover it on PATH
        extensions = { provider = "mlx-local", web_search = "off" },
      },
    },
  },
})
```

Configure `ai.helpers.model` too when helpers use Pi: the provider flag requires a model,
and helpers deliberately have a separate model selection. Missing models fail with a configuration
message rather than letting a local provider selection fall back to a cloud default.

Pi reads local provider configuration from `~/.pi/agent/models.json`:

```json
{
  "providers": {
    "mlx-local": {
      "baseUrl": "http://127.0.0.1:8081/v1",
      "api": "openai-completions",
      "apiKey": "not-needed",
      "models": [
        {
          "id": "mlx-community/Qwen3.6-27B-4bit",
          "contextWindow": 32768,
          "maxTokens": 2048
        }
      ]
    }
  }
}
```

## Manual MLX verification

This procedure covers the local MLX model acceptance criterion. The current review environment
had no local model server, so these steps were **not executed during this revision**.
The original PR author reported a run with KAT-Coder-V2.5-Dev-OptiQ-4bit-REAP-18B; that historical
report is not a new verification result.

1. Install `mlx-lm` in a Python virtual environment on an Apple Silicon machine with enough
   memory for the selected model, and start `mlx_lm.server --model mlx-community/Qwen3.6-27B-4bit --port 8081`.
2. Verify `curl http://127.0.0.1:8081/v1/models` lists the model, then confirm
   `pi --provider mlx-local --model mlx-community/Qwen3.6-27B-4bit -p "Say hello"` answers.
3. Open a throwaway Git repository in Neovim with the configuration above. Create a Pi chat.
   Ask it to write `probe.txt` containing `one`, read it, change `one` to `two`, and run
   `printf probe` in the shell. Approve only the calls expected by this procedure.
4. Verify Read, Write, Edit and Bash headers/results are rendered. Verify the real file contains
   `two`, `### Modified Files` appears, a `.vibing/diffs/*.diff` is saved, and `gd` opens it.
5. Send a second prompt about the file. Check the chat session id stays the same and
   `ps -eo pid,command` shows the same `pi --mode rpc` PID across the two completed turns.
6. Start a long reply and cancel with the documented chat cancel action. Send another prompt;
   it must answer on the same session without an error or duplicate response.
7. Put Bash in `permissions_deny`, then ask for a shell command that creates a marker file.
   Verify the denial reaches the model and the marker is absent. Repeat with a denied edit path.

## MCP

Pi 1.2.0 includes an MCP client. The backend does not inject Claude plugin manifests or install
another MCP bridge. Pi's own `mcp.json` supports stdio and streamable HTTP servers; see
[the upstream MCP reference](https://pi.dev/docs/latest/mcp).
Existing user/project Pi configuration remains Pi's responsibility, including project trust.
Pi normalizes server names to underscores in tool names. Such calls are still subject to the
vibing.nvim permission extension; there is no special automatic grant for this spelling.

For the bundled server, configure an explicit server command pointing at the checkout's
`agent-plugin/mcp-server/bin/run.sh`. The spawned process inherits `VIBING_NVIM_RPC_PORT` from
vibing.nvim; avoid hard-coding a port. `pi mcp list` checks connection and tool discovery.
This backend does not send prompts claiming `nvim_*` tools exist when no server was configured.
Plan, lightweight, and degraded runs disable MCP with `--no-mcp`.
`ai.agents.pi.mcp.enabled = false` also disables Pi's configured MCP servers.

## Validation status

Pi実機での検証はユーザー指示により未実施扱いです。
Real Pi, local-model integration, cancellation on a real process and MCP execution are
**not validated for acceptance in this revision**. No measured approval wait floor is declared;
approvals retain kill-and-retry. The unit and conformance tests use synthetic records based on
[the upstream RPC reference](https://pi.dev/docs/latest/rpc) and
[`rpc-types.ts`](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/src/modes/rpc/rpc-types.ts).
The documented MLX procedure above is pending manual execution. Issue #814 remains open.
