local cmp_adapter = require("vibing.infrastructure.completion.adapters.cmp")

describe("cmp completion adapter", function()
  it("keeps dotted model ids in the keyword pattern", function()
    local source = cmp_adapter.create()

    assert.is_true(source:get_keyword_pattern():find(".", 1, true) ~= nil)
  end)
end)
