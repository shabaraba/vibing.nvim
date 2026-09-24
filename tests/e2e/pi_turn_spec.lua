-- One real Pi turn, end to end through the shared adapter.
--
-- Unlike its four siblings, this spec needs a **model server** as well as a CLI. Pi is a harness:
-- it holds the agent loop and the tools, and the model comes from whatever its own `models.json`
-- points at. The configuration this was written and measured against is the one the feature exists
-- for (#814) — a local OpenAI-compatible endpoint:
--
--   mlx_lm.server --model mlx-community/Qwen3.6-27B-4bit --port 8081
--
--   ~/.pi/agent/models.json:
--   {"providers":{"mlx-local":{"baseUrl":"http://127.0.0.1:8081/v1",
--    "api":"openai-completions","apiKey":"not-needed",
--    "models":[{"id":"mlx-community/Qwen3.6-27B-4bit"}]}}}
--
-- Any provider Pi can reach works; nothing here is specific to MLX beyond the default model name.
-- Measured on that setup: a two-model-turn request with one bash call completed in 48s, which is
-- what the response budget below is sized from.
--
-- Deliberately not the tool-rendering assertion its codex and copilot siblings make. Pi does report
-- its tool calls, and the decoder is covered against a real capture in
-- `tests/fixtures/streams/pi/tool_turn.jsonl`; what is not dependable here is the *model*. Whether
-- a 27B local model reaches for bash on a given phrasing is a property of that model, not of this
-- integration, and an assertion that turns on it is a flake with a misleading name.
local helper = require("vibing.testing.e2e_helper")

if not helper.should_run() then
  return
end

local TIMEOUTS = {
  BUFFER_READY = 5000,
  -- Three times the 48s measured for this shape, because a local model's speed is the user's
  -- hardware. A green run returns as soon as the pattern matches, so this only bounds a hang.
  ASSISTANT_RESPONSE = 150000,
}

describe("E2E: pi completes a turn through the shared adapter", function()
  local nvim_instance

  before_each(function()
    nvim_instance = helper.spawn_backend_instance("pi")
  end)

  after_each(function()
    helper.cleanup_instance(nvim_instance)
  end)

  it("answers, and the turn is not an error", function()
    helper.send_keys(nvim_instance, ":VibingChat<CR>")

    local ok = helper.wait_for_buffer_name(nvim_instance, "%.md$", TIMEOUTS.BUFFER_READY)
    assert.is_true(ok, "chat buffer should be created")

    helper.send_keys(nvim_instance, "G")
    helper.send_keys(nvim_instance, "i")
    helper.send_keys(nvim_instance, 'Say "test"')
    helper.send_keys(nvim_instance, "<Esc>")
    helper.send_keys(nvim_instance, "<CR>")

    local reason
    ok, reason = helper.wait_for_assistant_turns(nvim_instance, 1, TIMEOUTS.ASSISTANT_RESPONSE)
    assert.is_true(ok, reason or "pi should answer without the turn failing")
  end)
end)
