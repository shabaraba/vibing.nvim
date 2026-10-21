local MODULE = "vibing.application.chat.search.helper_answer"

describe("helper answer", function()
  local HelperAnswer, streamed, reply, features

  ---@param call Vibing.Chat.Search.HelperCall?
  ---@return table? value
  ---@return string? error
  local function ask(call)
    local done, value, err = false, nil, nil
    HelperAnswer.ask("the prompt", { type = "object" }, function(v, e)
      done, value, err = true, v, e
    end, call)
    vim.wait(1000, function()
      return done
    end)
    return value, err
  end

  before_each(function()
    streamed, features = {}, {}
    reply = { chunks = {}, response = {} }
    package.loaded["vibing"] = {
      get_config = function()
        return { ai = { helpers = { model = "haiku", effort = "low" } } }
      end,
      get_helper_adapter = function()
        return {
          supports = function(_, feature)
            return features[feature] == true
          end,
          stream = function(_, prompt, opts, on_chunk, on_done)
            local path = opts.output_schema_path
            streamed[#streamed + 1] = {
              prompt = prompt,
              opts = opts,
              schema_file = path and table.concat(vim.fn.readfile(path), "\n"),
            }
            if reply.structured then
              opts.on_structured_output(reply.structured)
            end
            vim.schedule(function()
              for _, chunk in ipairs(reply.chunks) do
                on_chunk(chunk)
              end
              on_done(reply.response)
            end)
            return "turn-1", "process-1"
          end,
        }
      end,
    }
    package.loaded[MODULE] = nil
    HelperAnswer = require(MODULE)
  end)

  after_each(function()
    package.loaded["vibing"] = nil
    package.loaded[MODULE] = nil
  end)

  it("makes a lightweight call on the helper model, with no tools", function()
    reply.chunks = { '{"n": 1}' }

    ask()

    local opts = streamed[1].opts
    assert.is_true(opts.lightweight)
    assert.are.equal("haiku", opts.model)
    assert.is_nil(opts.exclusive_tools)
    assert.is_nil(opts.thinking)
  end)

  it("passes only the per-call fields it knows", function()
    reply.chunks = { '{"n": 1}' }

    ask({ thinking = false, lightweight = false })

    assert.are.equal(false, streamed[1].opts.thinking)
    assert.is_true(streamed[1].opts.lightweight)
  end)

  it("reads the JSON at the end of the answer when the backend has no structured output", function()
    reply.chunks = { "here:\n", '```json\n{"n": 2}\n```' }

    assert.are.same({ n = 2 }, ask())
  end)

  it("uses the structured payload instead of streamed prose", function()
    features = { structured_output = true, structured_output_tool = true }
    reply.structured = { groups = {} }
    reply.chunks = { "not JSON" }

    assert.are.same({ groups = {} }, ask())
    assert.are.same({ type = "object" }, streamed[1].opts.output_schema)
    assert.is_truthy(streamed[1].prompt:find("with StructuredOutput", 1, true))
  end)

  it("reports missing structured output instead of accepting prose", function()
    features = { structured_output = true }
    reply.chunks = { '{"groups": []}' }

    local value, err = ask()

    assert.is_nil(value)
    assert.are.equal("the search agent returned no structured result", err)
  end)

  it("writes a file schema for Codex and removes it when the turn ends", function()
    features = { structured_output = true, structured_output_file = true }
    reply.structured = { groups = {} }

    ask()

    local path = streamed[1].opts.output_schema_path
    assert.are.same({ type = "object" }, vim.json.decode(streamed[1].schema_file))
    assert.is_nil(streamed[1].prompt:find("with StructuredOutput", 1, true))
    assert.are.equal(0, vim.fn.filereadable(path))
  end)

  it("reports a failed turn and a missing adapter", function()
    reply.response = { error = "rate limited" }
    assert.are.equal("rate limited", select(2, ask()))

    package.loaded["vibing"].get_helper_adapter = function()
      return nil
    end
    assert.is_not_nil(select(2, ask()))
  end)
end)
