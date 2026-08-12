---@class Vibing.Testing.EvalHarness
---エージェント挙動の regression eval を回すハーネス。
---
---E2Eテスト（`tests/e2e/`）が検証しているのは**ハーネスの機構**——バッファが開くか、キー入力が
---届くか——であって、モデル+プロンプト+ツール定義の組み合わせが期待どおり振る舞うかではない。
---system promptやツールdescriptionを触ったときの退行は、今まで手動確認でしか気づけなかった。
---
---ここが見るのは1つだけ: **1リクエストで実際にどのツールがどんな引数で呼ばれたか**。
---採点は文章の良し悪しではなくその観測結果に対して行うので、決定的に判定できる。
---
---1タスク＝実CLI呼び出し1回＝実トークン消費。通常のテストスイートには入れず
---`pnpm run test:eval`（`tests/evals/run.lua`）からのみ回す。
local M = {}

---@class Vibing.Eval.Record 1試行の観測結果
---@field tool_calls { name: string, input: table }[] 呼ばれた順
---@field text string 最終的なアシスタント本文
---@field error string? リクエスト自体が失敗した場合

---@class Vibing.Eval.Task
---@field id string
---@field description string 何の契約を守らせたいのか
---@field prompt string モデルに送るメッセージ
---@field opts table? アダプターoptsの上書き（permissions_allow, lightweight など）
---@field scratch_repo boolean? 使い捨てgitリポジトリをcwdにして走らせる（Bashを許すタスク用）
---@field check fun(record: Vibing.Eval.Record): boolean, string? 合否と、落ちた理由

---@class Vibing.Eval.Attempt
---@field passed boolean
---@field reason string?
---@field record Vibing.Eval.Record

---@class Vibing.Eval.Result
---@field task Vibing.Eval.Task
---@field attempts Vibing.Eval.Attempt[]
---@field passed boolean pass@k: k回のうち1回でも通れば合格

---@class Vibing.Eval.Config
---@field attempts number? pass@kのk（デフォルト1）
---@field base_opts table? 全タスク共通のアダプターopts
---@field on_progress fun(result: Vibing.Eval.Result)? run_suiteが1タスク終えるごとに呼ぶ

---ツールを何度も往復するタスクがあるので、通常のリクエストより長めに待つ
local TIMEOUT_MS = 180000

---Bashを許すタスク用の使い捨てgitリポジトリを作る。
---evalは実際にコマンドを走らせる——それが「規約どおりにworktreeを作ったか」を観測する唯一の
---方法なので——ため、走らせる先が開発者の作業リポジトリであってはいけない。ここを省くと
---`pnpm run test:eval` のたびに本物のリポジトリにブランチとworktreeが残る。
---@return string path
function M.create_scratch_repo()
  local path = vim.fn.tempname() .. "_eval_repo"
  vim.fn.mkdir(path, "p")
  vim.fn.system({ "git", "-C", path, "init", "-q" })
  vim.fn.writefile({ "# eval scratch" }, vim.fs.joinpath(path, "README.md"))
  vim.fn.system({ "git", "-C", path, "add", "." })
  vim.fn.system({ "git", "-C", path, "-c", "user.email=eval@local", "-c", "user.name=eval", "commit", "-qm", "init" })
  return path
end

---1試行を回して観測結果を返す
---@param adapter table
---@param task Vibing.Eval.Task
---@param base_opts table
---@return Vibing.Eval.Record
local function run_attempt(adapter, task, base_opts)
  local record = { tool_calls = {}, text = "" }

  local opts = vim.tbl_extend("force", vim.deepcopy(base_opts), task.opts or {})
  if task.scratch_repo then
    opts.cwd = M.create_scratch_repo()
  end
  -- ツール呼び出しはアダプターがそのまま流してくるので、記録はここで完結する。
  -- フックやRPCを噛ませないぶん、evalがフック側の不調に巻き込まれない
  opts.on_tool_use_full = function(name, input)
    table.insert(record.tool_calls, { name = name, input = input or {} })
  end

  local done = false
  -- response.content はストリームしたチャンクの総和なので、本文はそちらだけ見れば足りる
  local handle_id = adapter:stream(task.prompt, opts, function() end, function(response)
    record.text = response.content or ""
    record.error = response.error
    done = true
  end)

  if not vim.wait(TIMEOUT_MS, function()
    return done
  end, 200) then
    record.error = string.format("timed out after %dms", TIMEOUT_MS)
    -- 待つのをやめてもCLIは走り続ける。放置すると次のタスクと並行してトークンを使い、
    -- Bashを許したタスクなら手を離れたところでコマンドまで走る
    if handle_id then
      pcall(function()
        adapter:cancel(handle_id)
      end)
    end
  end

  return record
end

---1タスクを最大attempts回まわす（pass@k）
---@param adapter table
---@param task Vibing.Eval.Task
---@param config Vibing.Eval.Config?
---@return Vibing.Eval.Result
function M.run_task(adapter, task, config)
  config = config or {}
  local attempts = math.max(1, config.attempts or 1)
  local result = { task = task, attempts = {}, passed = false }

  for _ = 1, attempts do
    local record = run_attempt(adapter, task, config.base_opts or {})

    local passed, reason
    if record.error then
      passed, reason = false, "request failed: " .. record.error
    else
      passed, reason = task.check(record)
    end

    table.insert(result.attempts, { passed = passed, reason = reason, record = record })

    -- 非決定性はpass@kで吸収する。1回通ればその契約は守れている
    if passed then
      result.passed = true
      break
    end
  end

  return result
end

---@param adapter table
---@param tasks Vibing.Eval.Task[]
---@param config Vibing.Eval.Config?
---@return Vibing.Eval.Result[]
function M.run_suite(adapter, tasks, config)
  config = config or {}
  local results = {}

  for _, task in ipairs(tasks) do
    local result = M.run_task(adapter, task, config)
    table.insert(results, result)
    if config.on_progress then
      config.on_progress(result)
    end
  end

  return results
end

---@param record Vibing.Eval.Record
---@param name string
---@return table? input 最初に見つかった呼び出しの引数
function M.find_tool_call(record, name)
  for _, call in ipairs(record.tool_calls) do
    if call.name == name then
      return call.input
    end
  end
  return nil
end

---MCPサーバーの登録形態でツール名の前置が変わる（プレーン登録とプラグイン登録）ので、
---接尾辞で照合する。can_use_tool.is_vibing_nvim_mcp_tool と同じ考え方
---@param record Vibing.Eval.Record
---@param suffix string 例: "nvim_ask_user_question"
---@return table? input
function M.find_mcp_call(record, suffix)
  for _, call in ipairs(record.tool_calls) do
    if call.name:sub(-#suffix) == suffix and call.name:find("^mcp__") then
      return call.input
    end
  end
  return nil
end

---@param results Vibing.Eval.Result[]
---@return string report
---@return boolean all_passed
function M.format_report(results)
  local lines = {}
  local passed_count = 0

  for _, result in ipairs(results) do
    if result.passed then
      passed_count = passed_count + 1
      local suffix = #result.attempts > 1 and string.format(" (attempt %d)", #result.attempts) or ""
      table.insert(lines, string.format("PASS  %s%s", result.task.id, suffix))
    else
      table.insert(lines, string.format("FAIL  %s", result.task.id))
      table.insert(lines, string.format("      %s", result.task.description))
      for i, attempt in ipairs(result.attempts) do
        table.insert(lines, string.format("      attempt %d: %s", i, attempt.reason or "no reason given"))
        local names = {}
        for _, call in ipairs(attempt.record.tool_calls) do
          table.insert(names, call.name)
        end
        table.insert(lines, string.format("      tools called: %s", #names > 0 and table.concat(names, ", ") or "(none)"))
      end
    end
  end

  table.insert(lines, "")
  table.insert(lines, string.format("%d/%d passed", passed_count, #results))

  return table.concat(lines, "\n"), passed_count == #results
end

return M
