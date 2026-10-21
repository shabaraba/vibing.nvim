local JsonAnswer = require("vibing.application.chat.search.json_answer")

describe("json answer", function()
  it("reads the last JSON block, not an example earlier in the text", function()
    local decoded = JsonAnswer.last('```json\n{"n": 1}\n```\nthen\n```json\n{"n": 2}\n```\n')

    assert.are.equal(2, decoded.n)
  end)

  it("takes a bare object at the very end", function()
    assert.are.equal(3, JsonAnswer.last('done: {"n": 3}').n)
  end)

  it("recovers omitted closing containers in a fenced result", function()
    local decoded = JsonAnswer.last('```json\n{"groups": [{"label": "g", "chats": []}]\n```')
    assert.are.equal("g", decoded.groups[1].label)
    local nested = JsonAnswer.last('```json\n{"groups": [{"label": "g", "chats": []\n```')
    assert.are.same({}, nested.groups[1].chats)
  end)

  it("ignores brackets and escaped quotes inside strings when closing containers", function()
    local text = vim.json.encode({ summary = 'a } [ "quoted" text' }):sub(1, -2)
    local decoded = JsonAnswer.last("```json\n" .. text .. "\n```")
    assert.are.equal('a } [ "quoted" text', decoded.summary)
  end)

  it("rejects incomplete values, unterminated strings and mismatched containers", function()
    for _, block in ipairs({ '{"groups":', '{"groups": ["unfinished', '{"groups": [}', '{"groups": [],' }) do
      local decoded, err = JsonAnswer.last("```json\n" .. block .. "\n```")
      assert.is_nil(decoded)
      assert.is_not_nil(err)
    end
  end)

  it("reports an answer with no JSON, or a malformed one", function()
    local _, missing = JsonAnswer.last("nothing here")
    local _, malformed = JsonAnswer.last("```json\n{oops\n```")

    assert.is_not_nil(missing)
    assert.is_not_nil(malformed)
  end)
end)
