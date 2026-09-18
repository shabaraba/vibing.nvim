-- E2E Tests: nvim_ask_user_question answered without killing the turn (#788)
--
-- The sibling of `nvim_ask_user_question_spec.lua`, which covers the shared choice-list UI on both
-- backends. What is under test here is the route: the reply to the MCP call is withheld, the turn
-- that asked stays open, and the user's text comes back as that call's result.
--
-- Its own file rather than a third case next door, because the E2E timeout gate models a spec
-- file's **serial** worst case and three real turns in one file exceed the harness budget.
local helper = require("vibing.testing.e2e_helper")

-- tests/e2e is swept by `test:lua` too, and this spec sends a real request to the CLI. Only
-- `test:e2e` sets VIBING_E2E=1; everything else skips rather than quietly spending tokens.
if not helper.should_run() then
  return
end

local TIMEOUTS = {
  CHAT_CREATION = 2000,
  BUFFER_READY = 5000,
  -- Same budget and the same reason as next door: the tool has to be found through ToolSearch and
  -- round-tripped through the MCP server before anything is rendered. Spent twice here, once for
  -- the question and once for the continuation the answer unblocks.
  ASSISTANT_RESPONSE = 60000,
}

describe("E2E: nvim_ask_user_question answered in place (claude)", function()
  local nvim_instance

  --- The marker the model can only learn from the answer, the same device the M1 probe uses: it
  --- appears nowhere in the prompt, so an echo of it cannot be explained by anything but the tool
  --- result reaching the model.
  local ANSWER_MARKER = "VIBINGANSWERED7731"

  before_each(function()
    nvim_instance = helper.spawn_nvim_instance({
      headless = true,
      init_script = "tests/e2e_init.lua",
      adapter = "claude",
    })
  end)

  after_each(function()
    helper.cleanup_instance(nvim_instance)
  end)

  local function eval_lua(code)
    return vim.fn.rpcrequest(nvim_instance.job_id, "nvim_exec_lua", code, {})
  end

  it("holds the turn open while it waits, and the answer arrives as the tool's result", function()
    helper.send_keys(nvim_instance, ":VibingChat<CR>")
    vim.wait(TIMEOUTS.CHAT_CREATION)

    local ok = helper.wait_for_buffer_name(nvim_instance, "%.md$", TIMEOUTS.BUFFER_READY)
    assert.is_true(ok, "Chat buffer should be created")

    helper.send_keys(nvim_instance, "G")
    helper.send_keys(nvim_instance, "i")
    helper.send_keys(
      nvim_instance,
      "Use the mcp__vibing-nvim__nvim_ask_user_question tool to ask me: 'Which option?' "
        .. "with options A and B. When you get my answer, reply with the last word of it and nothing else."
    )
    helper.send_keys(nvim_instance, "<Esc>")
    helper.send_keys(nvim_instance, "<CR>")

    local reason
    ok, reason = helper.wait_for_response(nvim_instance, "\n1%. A\n", TIMEOUTS.ASSISTANT_RESPONSE)
    assert.is_true(ok, reason or "Choice-list prompt should appear")

    -- The whole feature, in three readings taken while the prompt is on screen. On the kill route
    -- the turn is already dead here, so `responding` is false and the registry is empty — these
    -- cannot pass by accident on the behaviour #788 replaced.
    local state = eval_lua([[
      local bufnr = vim.api.nvim_get_current_buf()
      local chat = require("vibing.presentation.chat.view").get_chat_buffer(bufnr)
      return {
        responding = chat and chat:is_responding() or false,
        status = require("vibing.presentation.chat.modules.chat_status").get(bufnr),
        waiting = #require("vibing.infrastructure.rpc.pending_questions").list_for_chat(bufnr),
      }
    ]])
    assert.is_true(state.responding, "the turn that asked is still open")
    assert.equals("asked_question", state.status)
    assert.equals(1, state.waiting, "the MCP reply is being withheld")

    -- **The child reports its own result, and the parent reads a file.**
    --
    -- One `VibingResponseDone` autocmd, installed while the turn is still open, and no parent→child
    -- RPC at all between the answer and the end of the turn. The autocmd writes the count
    -- **whatever it is**, which is what lets the two assertions below stay separate.
    --
    -- The obvious shape — poll the child over RPC until the marker appears — is not wrong, and an
    -- earlier version of this spec was rewritten away from it for a reason that turned out to be
    -- false: the parent looked like it was dying under the polling, and it was really
    -- `PlenaryBustedFile`'s un-overridable 50s (see the `self-testing` skill). This shape is kept
    -- because it is the better one anyway — a report the child hands over is one round trip
    -- instead of hundreds, and it cannot itself perturb the turn it is measuring.
    local report_path = vim.fn.tempname()
    eval_lua(string.format(
      [[
      local path, marker = %q, %q
      vim.api.nvim_create_autocmd("User", {
        pattern = "VibingResponseDone",
        once = true,
        callback = function(ev)
          local bufnr = ev.data and ev.data.bufnr or vim.api.nvim_get_current_buf()
          local n = 0
          for _, line in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
            if line:find(marker, 1, true) then
              n = n + 1
            end
          end
          local f = io.open(path, "w")
          f:write(tostring(n))
          f:close()
        end,
      })
    ]],
      report_path,
      ANSWER_MARKER
    ))

    -- Answer in free text, which is what a question's answer is. The marker rides along with
    -- whatever option lines the user left behind.
    --
    -- **The text is written, not typed.** What is under test is what `<CR>` does with the buffer's
    -- contents, so the keystroke that stays a keystroke is `<CR>`; getting the characters in is
    -- setup, and typing `o`/`<Esc>` into a child that is draining a CLI's stdout is setup racing
    -- the thing being measured.
    eval_lua(string.format(
      [[
      local bufnr = vim.api.nvim_get_current_buf()
      local n = vim.api.nvim_buf_line_count(bufnr)
      vim.api.nvim_buf_set_lines(bufnr, n, n, false, { %q })
    ]],
      ANSWER_MARKER
    ))
    helper.send_keys(nvim_instance, "<CR>")

    -- `vim.loop.sleep` rather than a `vim.wait` predicate, for the same reason every helper here
    -- uses it: an `rpcrequest` inside a lua loop callback raises E5560. Nothing here makes one, but
    -- the shape is the one this file has already been bitten by.
    local occurrences
    local deadline = vim.loop.hrtime() + TIMEOUTS.ASSISTANT_RESPONSE * 1000000
    while vim.loop.hrtime() < deadline do
      if vim.fn.filereadable(report_path) == 1 then
        local content = table.concat(vim.fn.readfile(report_path), "")
        if content ~= "" then
          occurrences = tonumber(content)
          break
        end
      end
      vim.loop.sleep(200)
    end

    -- **Two failures, two assertions, deliberately.** The child writes the count whatever it is, so
    -- "no report" and "a report with the wrong number" cannot be the same red. The first is the
    -- harness or the turn dying; the second is this feature. Collapsing them would throw away the
    -- very distinction this reporting route was moved here to preserve.
    --
    -- There is deliberately **no `pending_questions` check here**, and its absence is not an
    -- oversight: `VibingResponseDone` fires from `_finish_turn`, which runs *after*
    -- `_release_blocked_questions`, so the registry is empty by then whether the answer was spent
    -- or released unanswered. The assertion would pass either way.
    assert.is_number(
      occurrences,
      "no report from the child: its turn never reached VibingResponseDone. This is the turn or the "
        .. "harness, not the answer — and if it is the harness, check the run's timeout first "
        .. "(`self-testing` → Running one spec by hand)"
    )
    -- Twice: once as what the user wrote, and again when the tool's **result** comes back and the
    -- renderer writes it under the `⏺ nvim_ask_user_question(...)` header (the model's own reply
    -- adds a third when it echoes it, which is what the prompt asked for, but that is a bonus and
    -- not what is counted on). On the kill route there is no result at all — the turn is dead
    -- before one could arrive — so the second occurrence is exactly the property under test: the
    -- reply that was withheld was handed back carrying the user's answer.
    assert.is_true(
      occurrences >= 2,
      string.format(
        "the turn finished, but the model's reply did not echo the marker it should have read from "
          .. "the answer (saw it %d time(s)) — the withheld reply did not carry the answer",
        occurrences
      )
    )
  end)
end)
