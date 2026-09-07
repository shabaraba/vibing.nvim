local slash_source = require("vibing.application.completion.sources.slash")

describe("Slash completion", function()
  it("detects dotted model ids as one argument query", function()
    local ctx = slash_source.get_trigger_context("/model gpt-5.", 13)

    assert.is_not_nil(ctx)
    assert.are.equal("argument", ctx.trigger)
    assert.are.equal("model", ctx.command_name)
    assert.are.equal("gpt-5.", ctx.query)
  end)
end)
