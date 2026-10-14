local Config = require("vibing.config")
local Vibing = require("vibing")
local Factory = require("vibing.infrastructure.adapter.factory")

describe("helper adapter selection", function()
  local previous, creates
  before_each(function()
    previous = {
      create = Factory.create,
      config = Vibing.config,
      adapter = Vibing.adapter,
      helper = Vibing._helper_adapter,
      helper_config = Vibing._helper_adapter_config,
    }
    creates = {}
    Factory.create = function(id, config)
      local adapter = { agent = id, config = config }
      table.insert(creates, adapter)
      return adapter
    end
    Vibing._helper_adapter = nil
    Vibing.adapter = { agent = "conversation" }
  end)
  after_each(function()
    Factory.create = previous.create
    Vibing.config, Vibing.adapter = previous.config, previous.adapter
    Vibing._helper_adapter, Vibing._helper_adapter_config = previous.helper, previous.helper_config
    Config.setup({})
  end)
  it("selects and caches a helper adapter independently of the conversation", function()
    Config.setup({ ai = { chat = { agent = "claude" }, helpers = { agent = "codex" } } })
    Vibing.config = Config.get()
    local helper = Vibing.get_helper_adapter()
    assert.equals("codex", helper.agent)
    assert.equals(helper, Vibing.get_helper_adapter())
    assert.equals("conversation", Vibing.get_adapter().agent)
    assert.equals(1, #creates)
    Config.setup({ ai = { chat = { agent = "grok" } } })
    Vibing.config = Config.get()
    assert.equals("grok", Vibing.get_helper_adapter().agent)
    assert.equals(2, #creates)
  end)
end)
