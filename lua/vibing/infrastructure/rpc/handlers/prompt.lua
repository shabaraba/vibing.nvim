--- The two prompts the model raises as queued tool calls, rather than by writing them.
---
--- `nvim_ask_question` is a multiple-choice question, `nvim_request_approval` is a confirmation the
--- model asks for before work it is about to do. **Neither call waits.** It validates its
--- arguments, appends an entry to the turn's queue (`turn_registry.push_prompt`) and returns at
--- once with text telling the model to end its turn. The chat drains the queue when the turn ends
--- (`cli_adapter.finish` → `send_message._handle_response`), draws the entries into the next unsent
--- section, and the answer is the next turn's message — exactly as a `vibing-question` block's
--- answer is.
---
--- **Why a tool rather than a trailing block.** A block is recognised only as the last thing the
--- turn wrote (`question_block.find_trailing`), so any instruction that makes the model append
--- something after it silently loses the question. A tool call has no position in the text, and its
--- arguments are checked here before anything is drawn. The block stays as the fallback for a
--- backend that cannot reach the bundled MCP server; see
--- `adapter/modules/ask_user_question_instructions.lua`.
---
--- **The caller is found by process id**, through `rpc/hook_scope.lua` — the same resolution
--- `nvim_permission_prompt` uses. A call that names no registered process is refused, never
--- guessed: a guess would draw a prompt in whichever chat happens to be streaming.
--- @module vibing.infrastructure.rpc.handlers.prompt

local HookScope = require("vibing.infrastructure.rpc.hook_scope")
local TurnRegistry = require("vibing.infrastructure.adapter.modules.turn_registry")
local QuestionBlock = require("vibing.presentation.chat.modules.question_block")

local M = {}

--- The cap `AskUserQuestion` had, from its one definition next to the parser. More than this in one
--- call is refused rather than truncated: a question nobody was shown is worse than a call the
--- model can correct.
local MAX_QUESTIONS = QuestionBlock.MAX_QUESTIONS

--- What the model may put in a confirmation, bounded so one call cannot fill the chat.
local MAX_DETAIL_LINES = 12
local MAX_LINE_CHARS = 500

--- What every successful call returns. The model must not go on working: the prompt is drawn when
--- the turn ends, so continuing only delays it.
local QUEUED_MESSAGE = "Queued. Nothing is shown to the user until this turn ends — end your turn now "
  .. "and do not wait for an answer or repeat the request."

--- @param message string
--- @return table
local function refused(message)
  return { ok = false, message = message }
end

--- The turn this call belongs to, or nil and the reason it was refused.
--- @param params table|nil
--- @return Vibing.TurnEntry|nil
--- @return string|nil
local function resolve_turn(params)
  local scope = HookScope.of(params)
  -- Both halves are refusals, for the same reason `permission_prompt.lua` refuses both: this path
  -- draws into a chat, and there is no chat to draw into without an identified turn.
  if scope.guessed then
    return nil, "vibing.nvim could not tell which chat this call came from, so nothing was queued."
  end
  if not scope.entry then
    return nil, "vibing.nvim has no turn open for this process, so nothing was queued. Do not retry "
      .. "this call outside a turn."
  end
  return scope.entry
end

--- One line of model-supplied text, made safe to draw.
---
--- `<!--` is broken the same way `permission_prompt_request.lua` breaks it: the unsent section uses
--- `<!-- vibing:req=... -->` to attribute an answer, and text that carries one must not become an
--- answer nobody gave.
--- @param text string
--- @return string
local function clean_line(text)
  local line = vim.trim(text:gsub("[\r\n]+", " "))
  line = line:sub(1, MAX_LINE_CHARS)
  return (line:gsub("<!%-%-", "<! --"))
end

--- `details` is iterated by the renderer, so it is rebuilt as a list of strings, never forwarded.
--- @param input any
--- @return table|nil
local function clean_input(input)
  if type(input) ~= "table" then
    return nil
  end

  local out = {}
  for _, key in ipairs({ "command", "file_path", "pattern", "url" }) do
    if type(input[key]) == "string" then
      out[key] = clean_line(input[key])
    end
  end

  if type(input.details) == "table" then
    local details = {}
    for _, line in ipairs(input.details) do
      if type(line) == "string" then
        table.insert(details, clean_line(line))
      end
      if #details >= MAX_DETAIL_LINES then
        break
      end
    end
    out.details = details
  end

  return next(out) and out or nil
end

--- Ask the user to choose among options.
--- @param params {process_id?: string, questions?: table|nil}
--- @return table
function M.ask_question(params)
  params = params or {}
  local turn, refusal = resolve_turn(params)
  if not turn then
    return refused(refusal)
  end

  local questions, invalid = QuestionBlock.validate(params.questions)
  if not questions then
    return refused("vibing.nvim did not queue this question: " .. tostring(invalid) .. ".")
  end
  if #questions > MAX_QUESTIONS then
    return refused(
      string.format(
        "vibing.nvim did not queue this question: at most %d questions fit in one call, and %d "
          .. "were sent.",
        MAX_QUESTIONS,
        #questions
      )
    )
  end

  if not TurnRegistry.push_prompt(turn.turn_id, { kind = "question", questions = questions }) then
    return refused("vibing.nvim's turn ended before this question was queued, so nothing is shown.")
  end
  return { ok = true, message = QUEUED_MESSAGE }
end

--- Ask the user to confirm something the model is about to do.
---
--- **Not the tool-permission gate.** It draws a prompt and the next message is the answer; it does
--- not authorise a later tool call. The hook's waiting approval (#778) and claude's
--- `nvim_permission_prompt` are the gate and stay separate: a gated call has to be held or refused
--- at the moment the CLI makes it, which a tool that returns immediately cannot do.
--- @param params {process_id?: string, reason?: string, tool?: string, input?: table|nil}
--- @return table
function M.request_approval(params)
  params = params or {}
  local turn, refusal = resolve_turn(params)
  if not turn then
    return refused(refusal)
  end

  if type(params.reason) ~= "string" or vim.trim(params.reason) == "" then
    return refused("vibing.nvim did not queue this confirmation: it needs a non-empty reason.")
  end

  local reason_lines = {}
  for _, line in ipairs(vim.split(params.reason, "\n", { plain = true })) do
    if #reason_lines >= MAX_DETAIL_LINES then
      break
    end
    table.insert(reason_lines, clean_line(line))
  end

  local entry = {
    kind = "approval",
    reason = table.concat(reason_lines, "\n"),
    input = clean_input(params.input),
  }
  if type(params.tool) == "string" and vim.trim(params.tool) ~= "" then
    entry.tool = clean_line(params.tool)
  end

  if not TurnRegistry.push_prompt(turn.turn_id, entry) then
    return refused("vibing.nvim's turn ended before this confirmation was queued, so nothing is shown.")
  end
  return { ok = true, message = QUEUED_MESSAGE }
end

return M
