# Adapter Development Guide

This guide explains how to create custom adapters for vibing.nvim to integrate with different LLM providers.

## Architecture Overview

```
User Input → ChatBuffer → Adapter → LLM Provider
                              ↓
                         Response Stream
```

All adapters inherit from `lua/vibing/adapters/base.lua` and implement a common interface.

## Existing Adapters

| Adapter      | File                      | Description                    |
| ------------ | ------------------------- | ------------------------------ |
| `agent_sdk`  | `adapters/agent_sdk.lua`  | Claude Agent SDK (recommended) |
| `claude`     | `adapters/claude.lua`     | Claude CLI direct              |
| `claude_acp` | `adapters/claude_acp.lua` | Anthropic Claude Protocol      |

## Creating a New Adapter

### Step 1: Create the Adapter File

Create `lua/vibing/adapters/your_adapter.lua`:

```lua
local Base = require("vibing.adapters.base")

---@class Vibing.YourAdapter : Vibing.Adapter
local YourAdapter = setmetatable({}, { __index = Base })
YourAdapter.__index = YourAdapter

function YourAdapter:new(config)
  local instance = Base.new(self, config)
  setmetatable(instance, YourAdapter)
  instance.name = "your_adapter"
  -- Initialize adapter-specific fields
  return instance
end

return YourAdapter
```

### Step 2: Implement Required Methods

#### `build_command(prompt, opts)`

Build the command or request parameters.

```lua
---@param prompt string User prompt
---@param opts Vibing.AdapterOpts Options (context, mode, model, etc.)
---@return table Command or request configuration
function YourAdapter:build_command(prompt, opts)
  return {
    url = "http://localhost:11434/api/generate",
    method = "POST",
    body = {
      model = opts.model or "llama2",
      prompt = prompt,
      stream = true,
    },
  }
end
```

#### `execute(prompt, opts)`

Synchronous execution (blocking).

```lua
---@param prompt string User prompt
---@param opts Vibing.AdapterOpts Options
---@return Vibing.Response Response with content and optional error
function YourAdapter:execute(prompt, opts)
  opts = opts or {}
  local result = { content = "" }
  local done = false

  self:stream(prompt, opts, function(chunk)
    result.content = result.content .. chunk
  end, function(response)
    if response.error then
      result.error = response.error
    end
    done = true
  end)

  vim.wait(120000, function() return done end, 100)
  return result
end
```

#### `stream(prompt, opts, on_chunk, on_done)`

Streaming execution (non-blocking, recommended).

```lua
---@param prompt string User prompt
---@param opts Vibing.AdapterOpts Options
---@param on_chunk fun(chunk: string) Callback for each text chunk
---@param on_done fun(response: Vibing.Response) Callback when complete
function YourAdapter:stream(prompt, opts, on_chunk, on_done)
  opts = opts or {}
  local config = self:build_command(prompt, opts)

  -- Example using curl via vim.system
  local cmd = {
    "curl", "-s", "-X", "POST",
    "-H", "Content-Type: application/json",
    "-d", vim.json.encode(config.body),
    config.url
  }

  self._handle = vim.system(cmd, {
    text = true,
    stdout = function(err, data)
      if data then
        vim.schedule(function()
          -- Parse streaming response
          local ok, parsed = pcall(vim.json.decode, data)
          if ok and parsed.response then
            on_chunk(parsed.response)
          end
        end)
      end
    end,
  }, function(obj)
    vim.schedule(function()
      self._handle = nil
      if obj.code ~= 0 then
        on_done({ content = "", error = "Request failed" })
      else
        on_done({ content = "" })
      end
    end)
  end)
end
```

#### `supports(feature)`

Declare supported features.

```lua
---@param feature string Feature name
---@return boolean
function YourAdapter:supports(feature)
  local features = {
    streaming = true,      -- Supports streaming responses
    tools = false,         -- Supports tool use
    model_selection = true, -- Supports multiple models
    context = true,        -- Supports file context
    session = false,       -- Supports session persistence
  }
  return features[feature] or false
end
```

#### `cancel()`

Cancel running request.

```lua
function YourAdapter:cancel()
  if self._handle then
    self._handle:kill(9)
    self._handle = nil
  end
end
```

### Step 3: Register the Adapter

Update `lua/vibing/init.lua` to recognize your adapter:

```lua
local function create_adapter(config)
  local adapter_name = config.adapter or "agent_sdk"

  if adapter_name == "your_adapter" then
    local YourAdapter = require("vibing.adapters.your_adapter")
    return YourAdapter:new(config)
  end
  -- ... existing adapters
end
```

### Step 4: Configure

Users can now use your adapter:

```lua
require("vibing").setup({
  adapter = "your_adapter",
  -- adapter-specific config
})
```

## Example: OpenAI-Compatible Adapter

For OpenAI API, Codex, or compatible local LLMs (LocalAI, vLLM, etc.):

```lua
local Base = require("vibing.adapters.base")

local OpenAI = setmetatable({}, { __index = Base })
OpenAI.__index = OpenAI

function OpenAI:new(config)
  local instance = Base.new(self, config)
  setmetatable(instance, OpenAI)
  instance.name = "openai"
  instance.base_url = config.openai and config.openai.base_url or "https://api.openai.com/v1"
  instance.api_key = config.openai and config.openai.api_key or os.getenv("OPENAI_API_KEY")
  return instance
end

function OpenAI:stream(prompt, opts, on_chunk, on_done)
  local cmd = {
    "curl", "-s", "-N",
    "-X", "POST",
    "-H", "Content-Type: application/json",
    "-H", "Authorization: Bearer " .. self.api_key,
    "-d", vim.json.encode({
      model = opts.model or "gpt-4",
      messages = {{ role = "user", content = prompt }},
      stream = true,
    }),
    self.base_url .. "/chat/completions"
  }

  self._handle = vim.system(cmd, {
    text = true,
    stdout = function(err, data)
      if data then
        vim.schedule(function()
          -- Parse SSE format: data: {...}
          for line in data:gmatch("[^\n]+") do
            if line:match("^data: ") then
              local json_str = line:sub(7)
              if json_str ~= "[DONE]" then
                local ok, parsed = pcall(vim.json.decode, json_str)
                if ok and parsed.choices and parsed.choices[1].delta.content then
                  on_chunk(parsed.choices[1].delta.content)
                end
              end
            end
          end
        end)
      end
    end,
  }, function(obj)
    vim.schedule(function()
      self._handle = nil
      on_done({ content = "" })
    end)
  end)
end

function OpenAI:supports(feature)
  return ({ streaming = true, model_selection = true, context = true })[feature] or false
end

return OpenAI
```

## Example: Ollama Adapter

For local LLMs via Ollama:

```lua
local Base = require("vibing.adapters.base")

local Ollama = setmetatable({}, { __index = Base })
Ollama.__index = Ollama

function Ollama:new(config)
  local instance = Base.new(self, config)
  setmetatable(instance, Ollama)
  instance.name = "ollama"
  instance.base_url = config.ollama and config.ollama.base_url or "http://localhost:11434"
  instance.default_model = config.ollama and config.ollama.model or "codellama"
  return instance
end

function Ollama:stream(prompt, opts, on_chunk, on_done)
  local cmd = {
    "curl", "-s", "-N",
    "-X", "POST",
    "-H", "Content-Type: application/json",
    "-d", vim.json.encode({
      model = opts.model or self.default_model,
      prompt = prompt,
      stream = true,
    }),
    self.base_url .. "/api/generate"
  }

  local buffer = ""
  self._handle = vim.system(cmd, {
    text = true,
    stdout = function(err, data)
      if data then
        vim.schedule(function()
          buffer = buffer .. data
          -- Ollama returns JSON lines
          while true do
            local newline = buffer:find("\n")
            if not newline then break end
            local line = buffer:sub(1, newline - 1)
            buffer = buffer:sub(newline + 1)
            local ok, parsed = pcall(vim.json.decode, line)
            if ok and parsed.response then
              on_chunk(parsed.response)
            end
          end
        end)
      end
    end,
  }, function(obj)
    vim.schedule(function()
      self._handle = nil
      on_done({ content = "" })
    end)
  end)
end

function Ollama:supports(feature)
  return ({ streaming = true, model_selection = true })[feature] or false
end

return Ollama
```

## Type Definitions

```lua
---@class Vibing.AdapterOpts
---@field streaming? boolean Enable streaming
---@field mode? string Execution mode (code, plan, etc.)
---@field model? string Model name
---@field context? string[] Context files
---@field permissions_allow? string[] Allowed tools
---@field permissions_deny? string[] Denied tools
---@field permission_mode? string Permission mode

---@class Vibing.Response
---@field content string Response text
---@field error? string Error message if failed
```

## Testing Your Adapter

Create `tests/your_adapter_spec.lua`:

```lua
describe("vibing.adapters.your_adapter", function()
  local YourAdapter

  before_each(function()
    package.loaded["vibing.adapters.your_adapter"] = nil
    YourAdapter = require("vibing.adapters.your_adapter")
  end)

  it("should create adapter instance", function()
    local adapter = YourAdapter:new({})
    assert.equals("your_adapter", adapter.name)
  end)

  it("should support streaming", function()
    local adapter = YourAdapter:new({})
    assert.is_true(adapter:supports("streaming"))
  end)
end)
```

## Best Practices

1. **Error Handling**: Always handle network errors and invalid responses gracefully
2. **Timeout**: Implement reasonable timeouts for requests
3. **Cancellation**: Support cancellation to avoid orphaned processes
4. **Streaming**: Prefer streaming for better UX (progressive display)
5. **Configuration**: Make API endpoints and keys configurable
6. **Buffer Management**: Handle partial JSON in streaming responses
