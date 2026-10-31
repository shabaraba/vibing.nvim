local TomlAssignments = require("vibing.core.utils.toml_assignments")

local function by_path(lines)
  local result = {}
  for _, entry in ipairs(TomlAssignments.scan(lines)) do
    result[table.concat(entry.path, ".")] = entry.raw == nil and "<nil>" or entry.raw
  end
  return result
end

describe("toml_assignments.scan", function()
  it("prefixes the table header and strips comments outside strings", function()
    local got = by_path({
      'model = "a#b" # chat default',
      "[model_providers.p]",
      'env_key = "K" # name only',
      "requires_openai_auth = false",
      'args = ["a"] # see [docs',
    })
    assert.are.same({
      ["model_providers.p.args"] = '["a"]',
      model = '"a#b"',
      ["model_providers.p.env_key"] = '"K"',
      ["model_providers.p.requires_openai_auth"] = "false",
    }, got)
  end)

  it("decodes quoted key segments in headers and keys", function()
    local got = by_path({
      '[model_providers."x.y"]',
      "'base_url' = 'http://h'",
      "[model_providers.p]",
      'http_headers."X-A" = "1"',
    })
    assert.equals("'http://h'", got["model_providers.x.y.base_url"])
    assert.equals('"1"', got["model_providers.p.http_headers.X-A"])
  end)

  it("keeps a one-line inline table or array whole", function()
    local got = by_path({ "[model_providers.p]", 'http_headers = { "X" = "y" }', 'args = ["a", "]"]' })
    assert.equals('{ "X" = "y" }', got["model_providers.p.http_headers"])
    assert.equals('["a", "]"]', got["model_providers.p.args"])
  end)

  it("reports a multi-line array as unsendable and does not read its lines as keys", function()
    local got = by_path({ "[model_providers.p]", "args = [", '  "x",', "  y = 1,", "]", 'name = "N"' })
    assert.are.same({ ["model_providers.p.args"] = "<nil>", ["model_providers.p.name"] = '"N"' }, got)
  end)

  it("reports a multi-line string as unsendable and skips its body", function()
    local got = by_path({ 'notes = """', 'model_provider = "evil"', '"""', 'one = """x"""' })
    assert.are.same({ notes = "<nil>", one = '"""x"""' }, got)
  end)

  it("files keys under an array of tables apart from a plain table", function()
    local got = by_path({ "[[model_providers.p.list]]", "a = 1" })
    assert.are.same({ ["[[]].model_providers.p.list.a"] = "1" }, got)
  end)

  it("decodes only a single complete string", function()
    assert.equals("a", TomlAssignments.decode_string('"a"'))
    assert.equals([[a\b]], TomlAssignments.decode_string([['a\b']]))
    assert.is_nil(TomlAssignments.decode_string('"a" "b"'))
    assert.is_nil(TomlAssignments.decode_string("1"))
    assert.is_nil(TomlAssignments.decode_string(nil))
  end)
end)
