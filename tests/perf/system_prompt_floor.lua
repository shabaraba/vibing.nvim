--- Measure the fixed per-request cost of a chat (the "floor") and what each part of it costs.
---
--- Run with:
---   VIBING_PERF=1 nvim --headless -u tests/minimal_init.lua -l tests/perf/system_prompt_floor.lua
---
--- **This spends real tokens** — one short turn per variant, on `VIBING_PERF_MODEL` (default
--- `haiku`, the cheapest; the floor is tool schemas and instructions, which do not depend on the
--- model). It exists because "what should a worker chat stop loading" is a decision to make from a
--- number, and #807 only measured the total (~51k–61k), never the parts.
---
--- Every variant starts from the argv vibing.nvim itself builds (`cli_command_builder.build`, the
--- same plugin directories, setting sources and system prompt a chat sends) and changes one thing.
--- Each run is a fresh session, so the floor is the whole input of its single request:
--- `input_tokens + cache_creation_input_tokens + cache_read_input_tokens`. The cache split moves
--- between runs (an identical prefix is served from the previous run's cache); the sum does not.
---
--- Read the deltas, not the totals: the CLI's own base prompt is in every row.
---
--- The vibing-nvim MCP server only contributes its tool schemas when it actually starts, so run
--- `./build.sh` first. The `mcp` column of the output says whether it did.

if os.getenv("VIBING_PERF") ~= "1" then
  print("tests/perf/system_prompt_floor.lua spends real tokens; set VIBING_PERF=1 to run it.")
  return
end

local MODEL = os.getenv("VIBING_PERF_MODEL") or "haiku"
local PROMPT = "Reply with exactly the word OK and nothing else."
local TIMEOUT_MS = 180000

local Config = require("vibing.config")
local Builder = require("vibing.infrastructure.adapter.modules.cli_command_builder")

Config.setup({ agent = { default_model = MODEL } })
local config = Config.get()

--- @param extra table|nil
--- @return string[]
local function vibing_argv(extra)
  local opts = vim.tbl_extend("force", {
    model = MODEL,
    cwd = vim.fn.getcwd(),
    chat_bufnr = 1,
    permission_mode = "default",
  }, extra or {})
  return Builder.build(PROMPT, opts, nil, config, nil)
end

--- Remove `flag` and the value after it, every occurrence.
--- @param argv string[]
--- @param flag string
--- @return string[]
local function without(argv, flag)
  local out, skip = {}, false
  for _, arg in ipairs(argv) do
    if skip then
      skip = false
    elseif arg == flag then
      skip = true
    else
      table.insert(out, arg)
    end
  end
  return out
end

--- Insert flags right after the binary. Not before the prompt: `--tools <tools...>` is variadic and
--- swallows the prompt that follows it, which once made a `--tools` row measure nothing at all.
--- @param argv string[]
--- @param flags string[]
--- @return string[]
local function with(argv, flags)
  local out = { argv[1] }
  vim.list_extend(out, flags)
  vim.list_extend(out, vim.list_slice(argv, 2))
  return out
end

--- @param argv string[]
--- @param flag string
--- @param value string
--- @return string[]
local function replacing(argv, flag, value)
  local out = vim.deepcopy(argv)
  for i, arg in ipairs(out) do
    if arg == flag then
      out[i + 1] = value
    end
  end
  return out
end

local base = vibing_argv()

--- @type { name: string, argv: string[] }[]
local VARIANTS = {
  { name = "vibing chat, as sent", argv = base },
  { name = "profile: focused", argv = vibing_argv({ profile = "focused" }) },
  { name = "profile: reviewer", argv = vibing_argv({ profile = "reviewer" }) },
  { name = "- --append-system-prompt", argv = without(base, "--append-system-prompt") },
  { name = "- --plugin-dir (vibing MCP, skills)", argv = without(base, "--plugin-dir") },
  { name = "--setting-sources '' (CLAUDE.md, rules)", argv = replacing(base, "--setting-sources", "") },
  {
    name = "--strict-mcp-config, no servers",
    argv = with(base, { "--strict-mcp-config", "--mcp-config", '{"mcpServers":{}}' }),
  },
  {
    name = "--tools: Bash,Read,Edit,Write,Glob,Grep",
    argv = with(base, { "--tools", "Bash,Read,Edit,Write,Glob,Grep" }),
  },
  {
    name = "--tools: the six + Skill",
    argv = with(base, { "--tools", "Bash,Read,Edit,Write,Glob,Grep,Skill" }),
  },
  {
    name = "--tools: the six + Agent",
    argv = with(base, { "--tools", "Bash,Read,Edit,Write,Glob,Grep,Agent" }),
  },
  {
    name = "--tools: the six + ToolSearch",
    argv = with(base, { "--tools", "Bash,Read,Edit,Write,Glob,Grep,ToolSearch" }),
  },
  {
    name = "lean: focused, no project (user,local)",
    argv = replacing(vibing_argv({ profile = "focused" }), "--setting-sources", "user,local"),
  },
  { name = "+ --exclude-dynamic-system-prompt-sections", argv = with(base, { "--exclude-dynamic-system-prompt-sections" }) },
  {
    name = "bare claude -p (no vibing flags)",
    argv = { base[1], "-p", "--output-format", "stream-json", "--verbose", "--model", MODEL, PROMPT },
  },
}

--- @param argv string[]
--- @return { floor: number?, input: number?, write: number?, read: number?, turns: number?, tools: number?, mcp: string, error: string? }
local function run(argv)
  local result = vim.system(argv, { cwd = vim.fn.getcwd(), text = true }):wait(TIMEOUT_MS)
  local row = { mcp = "?" }
  for line in (result.stdout or ""):gmatch("[^\n]+") do
    local ok, event = pcall(vim.json.decode, line)
    if ok and type(event) == "table" then
      if event.type == "system" and event.subtype == "init" then
        row.tools = type(event.tools) == "table" and #event.tools or nil
        local states = {}
        for _, server in ipairs(type(event.mcp_servers) == "table" and event.mcp_servers or {}) do
          table.insert(states, string.format("%s=%s", tostring(server.name), tostring(server.status)))
        end
        row.mcp = #states > 0 and table.concat(states, ",") or "none"
      elseif event.type == "result" and type(event.usage) == "table" then
        local u = event.usage
        row.input = tonumber(u.input_tokens) or 0
        row.write = tonumber(u.cache_creation_input_tokens) or 0
        row.read = tonumber(u.cache_read_input_tokens) or 0
        row.floor = row.input + row.write + row.read
        -- More than one request means the model used a tool and `usage` is a sum: that row's
        -- floor is not comparable with the others and has to be re-run, not read.
        row.turns = tonumber(event.num_turns)
      end
    end
  end
  if not row.floor then
    row.error = string.format("exit %s: %s", tostring(result.code), ((result.stderr or ""):gsub("%s+", " ")):sub(1, 200))
  end
  return row
end

--- `print` under `nvim -l` goes through the message layer, which dropped a newline between two rows
--- in practice; the table is the output, so write it to stdout directly.
--- @param line string
local function emit(line)
  io.stdout:write(line, "\n")
end

emit(string.format("claude %s, model %s, cwd %s", (vim.fn.system({ base[1], "--version" }):gsub("%s+$", "")), MODEL, vim.fn.getcwd()))
emit(string.format("%-44s %8s %8s %5s %6s  %s", "variant", "floor", "delta", "turns", "tools", "mcp"))

--- `VIBING_PERF_ONLY=<substring>` re-runs only the matching variants (plus the reference row).
local only = os.getenv("VIBING_PERF_ONLY")

local reference
for index, variant in ipairs(VARIANTS) do
  if only and index > 1 and not variant.name:find(only, 1, true) then
    goto continue
  end
  local row = run(variant.argv)
  if row.error then
    emit(string.format("%-44s %s", variant.name, row.error))
  else
    reference = reference or row.floor
    emit(
      string.format(
        "%-44s %8d %+8d %5s %6s  %s",
        variant.name,
        row.floor,
        row.floor - reference,
        tostring(row.turns or "?"),
        tostring(row.tools or "?"),
        row.mcp
      )
    )
  end
  ::continue::
end
