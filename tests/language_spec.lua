-- Tests for vibing.utils.language module

describe("vibing.utils.language", function()
  local Language

  before_each(function()
    package.loaded["vibing.utils.language"] = nil
    Language = require("vibing.utils.language")
  end)

  describe("language_names", function()
    it("should contain common language mappings", function()
      assert.equals("Japanese", Language.language_names.ja)
      assert.equals("English", Language.language_names.en)
      assert.equals("Chinese", Language.language_names.zh)
      assert.equals("Korean", Language.language_names.ko)
      assert.equals("French", Language.language_names.fr)
    end)
  end)

  describe("get_language_instruction", function()
    it("should return empty string for nil", function()
      assert.equals("", Language.get_language_instruction(nil))
    end)

    it("should return empty string for empty string", function()
      assert.equals("", Language.get_language_instruction(""))
    end)

    it("should return empty string for 'en'", function()
      assert.equals("", Language.get_language_instruction("en"))
    end)

    it("should return instruction for 'ja'", function()
      assert.equals(" in Japanese", Language.get_language_instruction("ja"))
    end)

    it("should return instruction for 'fr'", function()
      assert.equals(" in French", Language.get_language_instruction("fr"))
    end)

    it("should return empty string for unknown language code", function()
      assert.equals("", Language.get_language_instruction("unknown"))
    end)
  end)

  describe("add_language_instruction", function()
    it("should return prompt unchanged when no language code", function()
      local prompt = "Fix the following code:"
      assert.equals(prompt, Language.add_language_instruction(prompt, nil))
    end)

    it("should return prompt unchanged for 'en'", function()
      local prompt = "Fix the following code:"
      assert.equals(prompt, Language.add_language_instruction(prompt, "en"))
    end)

    it("should add instruction before colon", function()
      local prompt = "Fix the following code:"
      local expected = "Fix the following code in Japanese:"
      assert.equals(expected, Language.add_language_instruction(prompt, "ja"))
    end)

    it("should add instruction at end when no colon", function()
      local prompt = "Fix the following code"
      local expected = "Fix the following code in Japanese"
      assert.equals(expected, Language.add_language_instruction(prompt, "ja"))
    end)

    it("should handle unknown language code", function()
      local prompt = "Fix the following code:"
      assert.equals(prompt, Language.add_language_instruction(prompt, "unknown"))
    end)
  end)

  describe("get_language_code", function()
    it("should return nil for nil language", function()
      assert.is_nil(Language.get_language_code(nil, "inline"))
    end)

    it("should return string as-is", function()
      assert.equals("ja", Language.get_language_code("ja", "inline"))
      assert.equals("en", Language.get_language_code("en", "chat"))
    end)

    it("should return action-specific code from table", function()
      local language = {
        default = "en",
        inline = "ja",
        chat = "fr",
      }
      assert.equals("ja", Language.get_language_code(language, "inline"))
      assert.equals("fr", Language.get_language_code(language, "chat"))
    end)

    it("should return default when action-specific code not set", function()
      local language = {
        default = "ja",
      }
      assert.equals("ja", Language.get_language_code(language, "inline"))
      assert.equals("ja", Language.get_language_code(language, "chat"))
    end)

    it("should return nil when table has no matching keys", function()
      local language = {}
      assert.is_nil(Language.get_language_code(language, "inline"))
    end)
  end)
end)
