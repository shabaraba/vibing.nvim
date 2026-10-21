--- Entry point for `pnpm run test:eval:chat-search`.
---
--- Runs every query in `cases.lua` through the real `:VibingChatSearch` use case against the
--- fixture corpus and prints recall and precision. It spends real tokens and never fails the
--- process on a low score: its job is to compare models, not to gate a build.
---
--- Env:
---   VIBING_EVAL_MODEL     helper model to evaluate, default haiku (the shipped default)
---   VIBING_EVAL_EFFORT    helper effort, default the shipped one
---   VIBING_EVAL_ATTEMPTS  runs per query, averaged, default 1
---   VIBING_EVAL_ONLY      Lua pattern; only run cases whose id matches
---   VIBING_EVAL_OUT       write the raw results as JSON to this path

local Eval = require("vibing.testing.chat_search_eval")
local Fs = require("vibing.core.utils.fs")

local TIMEOUT_MS = 600000
local CORPUS = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h:h")
  .. "/tests/fixtures/chat_search/corpus/"

local model = os.getenv("VIBING_EVAL_MODEL") or "haiku"
local effort = os.getenv("VIBING_EVAL_EFFORT")

require("vibing").setup({
  integrations = { nvim = { enabled = true } },
  ai = { helpers = { model = model, effort = effort } },
})

-- `setup()` starts the RPC server on `vim.schedule`. A search started before it is listening
-- spawns a CLI with no `VIBING_NVIM_RPC_PORT`, whose hook then asks some other Neovim and runs
-- under that one's permissions instead of this turn's `exclusive_tools`.
local RpcServer = require("vibing.infrastructure.rpc.server")
if not vim.wait(10000, RpcServer.is_running, 50) then
  io.stderr:write("The RPC server did not start\n")
  os.exit(1)
end

---The search runs in a throwaway git repository that ignores `.vibing/`, as a real project
---does: the Grep and Glob tools honour ignore files and find nothing there, and a corpus they
---can read makes the eval easier than real use. Its own repository also keeps the agent out of
---this checkout's `.vibing/chat/`.
---@return string chat_dir
local function stage_corpus()
  local root = vim.fn.tempname() .. "_chat_search_eval"
  local chat_dir = root .. "/.vibing/chat"
  Fs.ensure_dir(chat_dir)
  vim.system({ "git", "init", "-q", root }):wait()
  vim.fn.writefile({ ".vibing/" }, root .. "/.gitignore")
  for _, name in ipairs(vim.fn.readdir(CORPUS)) do
    vim.fn.writefile(vim.fn.readfile(CORPUS .. name, "b"), chat_dir .. "/" .. name, "b")
  end
  vim.cmd.cd(root)
  return chat_dir
end

---The search terms and the ranked candidates of the current search, so a miss can be told apart
---as a ranking miss (never a candidate) or a judgement miss (a candidate the model dropped).
local trace = {}
local ChatGrep = require("vibing.application.chat.search.chat_grep")
local grep = ChatGrep.run
ChatGrep.run = function(dir, concepts, callback)
  trace.concepts = concepts
  grep(dir, concepts, function(candidates, err)
    trace.candidates = vim.tbl_map(function(candidate)
      return vim.fn.fnamemodify(candidate.path, ":t")
    end, candidates or {})
    callback(candidates, err)
  end)
end

---@param query string
---@param chat_dir string
---@return {names: string[], error: string?, tools: string[], seconds: number, concepts: string[][]?, candidates: string[]?}
local function search(query, chat_dir)
  local outcome
  local tools = {}
  trace = {}
  local started = vim.uv.hrtime()
  require("vibing.application.chat.use_cases.search_chats").run(query, chat_dir, function(o)
    outcome = o
  end, function(label)
    tools[#tools + 1] = string.format("%.1fs %s", (vim.uv.hrtime() - started) / 1e9, label)
  end)

  if not vim.wait(TIMEOUT_MS, function()
    return outcome ~= nil
  end, 200) then
    outcome = { results = {}, error = string.format("timed out after %dms", TIMEOUT_MS) }
  end

  return {
    names = vim.tbl_map(function(result)
      return vim.fn.fnamemodify(result.entity.path, ":t")
    end, outcome.results),
    error = outcome.error,
    tools = tools,
    seconds = (vim.uv.hrtime() - started) / 1e9,
    concepts = trace.concepts,
    candidates = trace.candidates,
  }
end

local cases = require("tests.evals.chat_search.cases")
local only = os.getenv("VIBING_EVAL_ONLY")
if only then
  cases = vim.tbl_filter(function(case)
    return case.id:find(only) ~= nil
  end, cases)
end
local attempts = tonumber(os.getenv("VIBING_EVAL_ATTEMPTS") or "") or 1

local chat_dir = stage_corpus()
io.write(string.format("model=%s effort=%s, %d case(s) x %d attempt(s)\n\n", model, effort or "(default)", #cases, attempts))

local scores, raw = {}, {}
for _, case in ipairs(cases) do
  for attempt = 1, attempts do
    local run = search(case.query, chat_dir)
    local score = run.error and Eval.failed(case, run.error) or Eval.score(case, run.names)
    scores[#scores + 1] = score
    raw[#raw + 1] = { case = case.id, attempt = attempt, run = run, score = score }

    io.write(
      string.format(
        "%s  %-36s R=%.2f P=%.2f  %d tools %.0fs\n",
        score.exact and "EXACT" or "     ",
        case.id,
        score.recall,
        score.precision,
        #run.tools,
        run.seconds
      )
    )
    for _, line in ipairs(Eval.format_attempt(case, score, run.candidates)) do
      io.write("       " .. line .. "\n")
    end
    io.flush()
  end
end

local total = Eval.summarize(scores)
io.write(
  string.format(
    "\nrecall %.3f  precision %.3f  exact %d/%d  errors %d\n",
    total.recall,
    total.precision,
    total.exact,
    total.count,
    total.errors
  )
)

local out = os.getenv("VIBING_EVAL_OUT")
if out then
  vim.fn.writefile({ vim.json.encode({ model = model, effort = effort, summary = total, attempts = raw }) }, out)
end

os.exit(0)
