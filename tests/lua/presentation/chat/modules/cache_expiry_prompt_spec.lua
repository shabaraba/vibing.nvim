-- Tests for the three answers to the pre-send cache prompt, and for the rule that outranks all of
-- them: anything that goes wrong inside the check sends the message rather than blocking it.

describe("cache_expiry_prompt.guard", function()
  local Prompt = require("vibing.presentation.chat.modules.cache_expiry_prompt")
  local CacheExpiry = require("vibing.application.chat.cache_expiry")

  local original_evaluate
  local original_ui_select

  before_each(function()
    original_evaluate = CacheExpiry.evaluate
    original_ui_select = vim.ui.select
  end)

  after_each(function()
    CacheExpiry.evaluate = original_evaluate
    vim.ui.select = original_ui_select
    package.loaded["vibing.application.chat.use_cases.carry_over"] = nil
    package.loaded["vibing.presentation.chat.controller"] = nil
  end)

  --- @param decision table|nil what evaluate() answers
  local function stub_evaluate(decision)
    CacheExpiry.evaluate = function()
      return decision
    end
  end

  local EXPIRED = { elapsed_sec = 5000, context = 205000 }

  it("sends straight through when there is nothing to warn about", function()
    stub_evaluate(nil)
    local asked = false
    vim.ui.select = function()
      asked = true
    end

    local sent = false
    Prompt.guard({}, function()
      sent = true
    end)

    assert.is_true(sent)
    assert.is_false(asked)
  end)

  it("names the elapsed time and the size that is about to be rewritten", function()
    stub_evaluate(EXPIRED)
    local prompt
    vim.ui.select = function(_, opts)
      prompt = opts.prompt
    end

    Prompt.guard({}, function() end)

    assert.truthy(prompt:find("1h23m", 1, true))
    assert.truthy(prompt:find("205k", 1, true))
  end)

  it("sends when the answer is 'Send anyway'", function()
    stub_evaluate(EXPIRED)
    vim.ui.select = function(items, _, on_choice)
      on_choice(items[1])
    end

    local sent = false
    Prompt.guard({}, function()
      sent = true
    end)

    assert.is_true(sent)
  end)

  it("does nothing when cancelled, leaving the message unsent", function()
    stub_evaluate(EXPIRED)
    vim.ui.select = function(_, _, on_choice)
      on_choice(nil)
    end

    local sent = false
    Prompt.guard({}, function()
      sent = true
    end)

    assert.is_false(sent)
  end)

  it("carries the message into a new chat instead of sending it", function()
    stub_evaluate(EXPIRED)
    vim.ui.select = function(items, _, on_choice)
      on_choice(items[2])
    end

    local carried, opened
    package.loaded["vibing.application.chat.use_cases.carry_over"] = {
      execute = function(_, message)
        carried = message
        return { get_file_path = function() return "/tmp/new.md" end }
      end,
    }
    package.loaded["vibing.presentation.chat.controller"] = {
      open_continuation = function(session)
        opened = session
      end,
    }

    local sent = false
    Prompt.guard({
      extract_user_message = function()
        return "carry me over"
      end,
    }, function()
      sent = true
    end)

    assert.is_false(sent)
    assert.equals("carry me over", carried)
    assert.is_not_nil(opened)
  end)

  it("sends rather than blocking when the check itself raises", function()
    CacheExpiry.evaluate = function()
      error("boom")
    end

    local sent = false
    Prompt.guard({}, function()
      sent = true
    end)

    assert.is_true(sent)
  end)
end)
