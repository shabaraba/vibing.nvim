---@diagnostic disable: undefined-field
--- The approval prompt reaches the buffer through two relay closures, and a dropped argument there
--- is **silent**.
---
--- `permission.lua` and `codex_native_approval.lua` both call `turn.on_approval_required(...)`. That
--- is `send_message.lua`'s closure, which calls the `ChatBuffer` callback table's
--- `insert_approval_request`, which calls the method of the same name. Three parameter lists, two
--- of them hand-written forwardings.
---
--- #861 added a sixth parameter and both forwardings kept their five. Nothing failed: the prompt was
--- drawn, the human answered it, and the answer alone fell through a vocabulary check one layer away
--- and was discarded — so the CLI waited out its limit with no error anywhere. Every behavioural
--- spec was green, because each of them stubbed one of the two closures.
---
--- So this is read out of the source, the way `identity_spec.lua` reads the character class out of
--- the shell scripts: the only thing that can hold three hand-written lists equal is something that
--- compares them.
local function source(path)
  local file = assert(io.open(path, "r"), "could not read " .. path)
  local text = file:read("*a")
  file:close()
  return text
end

--- @param text string
--- @param pattern string capturing the parenthesised parameter list
--- @return string[] names
local function params(text, pattern)
  local list = text:match(pattern)
  assert(list, "no parameter list matched " .. pattern)
  local names = {}
  for name in list:gmatch("[%w_]+") do
    table.insert(names, name)
  end
  return names
end

describe("the approval prompt's relay closures", function()
  local root = vim.fn.getcwd()
  local buffer_src = source(root .. "/lua/vibing/presentation/chat/buffer.lua")
  local send_src = source(root .. "/lua/vibing/application/chat/send_message.lua")

  -- The method every forwarding eventually reaches; `self` is dropped by the colon call.
  local declared = params(buffer_src, "function ChatBuffer:insert_approval_request%(([^)]*)%)")

  it("the ChatBuffer callback table forwards every parameter the method declares", function()
    local relay = params(buffer_src, "insert_approval_request = function%(([^)]*)%)")
    assert.same(declared, relay, "the callback table's parameter list drifted from the method's")

    local forwarded = params(buffer_src, "return self:insert_approval_request%(([^)]*)%)")
    assert.same(declared, forwarded, "the callback table accepts parameters it does not pass on")
  end)

  it("send_message's on_approval_required forwards every parameter too", function()
    local relay = params(send_src, "on_approval_required = function%(([^)]*)%)")
    assert.same(declared, relay, "send_message's closure takes fewer parameters than the method")

    local forwarded = params(send_src, "callbacks%.insert_approval_request%(([^)]*)%)")
    assert.same(declared, forwarded, "send_message's closure accepts parameters it does not pass on")
  end)

  it("the turn registry's annotation names the same parameters", function()
    -- The adapter calls through this type, so an annotation one parameter short is how a caller
    -- learns to stop passing the sixth.
    local registry_src = source(root .. "/lua/vibing/infrastructure/adapter/modules/turn_registry.lua")
    local annotated = registry_src:match("@field on_approval_required%?%s*fun%(([^)]*)%)")
    assert.is_not_nil(annotated, "turn_registry no longer annotates on_approval_required")

    local names = {}
    -- `name?: type` for the optional ones, so the `?` is part of the separator, not of the name.
    for name in annotated:gmatch("([%w_]+)%??%s*:") do
      table.insert(names, name)
    end
    assert.same(declared, names, "the annotation and the method disagree about the parameter list")
  end)
end)
