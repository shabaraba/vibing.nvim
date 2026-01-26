local Factory = require("vibing.infrastructure.section_parser.factory")

describe("SectionParserFactory", function()
  before_each(function()
    Factory.reset_cache()
  end)

  describe("get_parser", function()
    it("returns grep_parser when grep is available", function()
      local parser = Factory.get_parser()
      -- On macOS/Linux, should return grep_parser
      assert.is_truthy(parser)
      assert.is_truthy(parser.name)
    end)

    it("returns line_parser when forced fallback", function()
      local parser = Factory.get_parser(true)
      assert.equals("line_parser", parser.name)
    end)

    it("caches the parser instance", function()
      local parser1 = Factory.get_parser()
      local parser2 = Factory.get_parser()
      assert.equals(parser1, parser2)
    end)

    it("returns different instance after reset", function()
      local parser1 = Factory.get_parser()
      Factory.reset_cache()
      local parser2 = Factory.get_parser()
      -- They may be equal in value but different instances
      assert.is_truthy(parser1)
      assert.is_truthy(parser2)
    end)
  end)

  describe("get_current_parser_name", function()
    it("returns nil before get_parser is called", function()
      assert.is_nil(Factory.get_current_parser_name())
    end)

    it("returns parser name after get_parser is called", function()
      Factory.get_parser()
      local name = Factory.get_current_parser_name()
      assert.is_truthy(name)
    end)
  end)
end)
