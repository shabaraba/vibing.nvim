-- Tests for approval_parser module

describe("vibing.presentation.chat.modules.approval_parser", function()
  local ApprovalParser

  before_each(function()
    package.loaded["vibing.presentation.chat.modules.approval_parser"] = nil
    ApprovalParser = require("vibing.presentation.chat.modules.approval_parser")
  end)

  describe("is_approval_response", function()
    it("should return true for allow_once pattern", function()
      local message = "1. allow_once - Allow this execution only"
      assert.is_true(ApprovalParser.is_approval_response(message))
    end)

    it("should return true for deny_once pattern", function()
      local message = "2. deny_once - Deny this execution only"
      assert.is_true(ApprovalParser.is_approval_response(message))
    end)

    it("should return true for allow_for_session pattern", function()
      local message = "3. allow_for_session - Allow for this session"
      assert.is_true(ApprovalParser.is_approval_response(message))
    end)

    it("should return true for deny_for_session pattern", function()
      local message = "4. deny_for_session - Deny for this session"
      assert.is_true(ApprovalParser.is_approval_response(message))
    end)

    it("should return true with leading spaces", function()
      local message = "  1. allow_once - Allow this execution only"
      assert.is_true(ApprovalParser.is_approval_response(message))
    end)

    it("should return true with quote marker", function()
      local message = "> 1. allow_once - Allow this execution only"
      assert.is_true(ApprovalParser.is_approval_response(message))
    end)

    it("should return false for non-approval message", function()
      local message = "Please run the tests"
      assert.is_false(ApprovalParser.is_approval_response(message))
    end)

    it("should return false for empty string", function()
      assert.is_false(ApprovalParser.is_approval_response(""))
    end)

    it("should return false for nil", function()
      assert.is_false(ApprovalParser.is_approval_response(nil))
    end)

    it("should return false for non-string", function()
      assert.is_false(ApprovalParser.is_approval_response(123))
    end)
  end)

  describe("parse_approval_response", function()
    it("should parse allow_once action", function()
      local message = "1. allow_once - Allow this execution only"
      local result = ApprovalParser.parse_approval_response(message)
      assert.is_not_nil(result)
      assert.equals("allow_once", result.action)
    end)

    it("should parse deny_once action", function()
      local message = "2. deny_once - Deny this execution only"
      local result = ApprovalParser.parse_approval_response(message)
      assert.is_not_nil(result)
      assert.equals("deny_once", result.action)
    end)

    it("should parse allow_for_session action", function()
      local message = "3. allow_for_session - Allow for this session"
      local result = ApprovalParser.parse_approval_response(message)
      assert.is_not_nil(result)
      assert.equals("allow_for_session", result.action)
    end)

    it("should parse deny_for_session action", function()
      local message = "4. deny_for_session - Deny for this session"
      local result = ApprovalParser.parse_approval_response(message)
      assert.is_not_nil(result)
      assert.equals("deny_for_session", result.action)
    end)

    it("should parse with leading whitespace", function()
      local message = "  1. allow_once - Allow this execution only"
      local result = ApprovalParser.parse_approval_response(message)
      assert.is_not_nil(result)
      assert.equals("allow_once", result.action)
    end)

    it("should parse with quote marker", function()
      local message = "> 3. allow_for_session - Allow for this session"
      local result = ApprovalParser.parse_approval_response(message)
      assert.is_not_nil(result)
      assert.equals("allow_for_session", result.action)
    end)

    it("should parse multiline message with approval", function()
      local message = [[
Some text
3. allow_for_session - Allow for this session
More text
]]
      local result = ApprovalParser.parse_approval_response(message)
      assert.is_not_nil(result)
      assert.equals("allow_for_session", result.action)
    end)

    it("should return nil for non-approval message", function()
      local message = "Please run the tests"
      local result = ApprovalParser.parse_approval_response(message)
      assert.is_nil(result)
    end)

    it("should return nil for empty string", function()
      local result = ApprovalParser.parse_approval_response("")
      assert.is_nil(result)
    end)

    it("should return nil for nil input", function()
      local result = ApprovalParser.parse_approval_response(nil)
      assert.is_nil(result)
    end)
  end)

  describe("generate_response_message", function()
    it("should generate message for allow_once", function()
      local message = ApprovalParser.generate_response_message("allow_once", "WebSearch")
      assert.is_not_nil(message:match("approved"))
      assert.is_not_nil(message:match("WebSearch"))
      assert.is_not_nil(message:match("try again"))
    end)

    it("should generate message for deny_once", function()
      local message = ApprovalParser.generate_response_message("deny_once", "Bash")
      assert.is_not_nil(message:match("denied"))
      assert.is_not_nil(message:match("Bash"))
      assert.is_not_nil(message:match("alternative"))
    end)

    it("should generate message for allow_for_session", function()
      local message = ApprovalParser.generate_response_message("allow_for_session", "Edit")
      assert.is_not_nil(message:match("approved"))
      assert.is_not_nil(message:match("Edit"))
      assert.is_not_nil(message:match("session"))
    end)

    it("should generate message for deny_for_session", function()
      local message = ApprovalParser.generate_response_message("deny_for_session", "Write")
      assert.is_not_nil(message:match("denied"))
      assert.is_not_nil(message:match("Write"))
      assert.is_not_nil(message:match("session"))
    end)

    it("should handle nil tool name", function()
      local message = ApprovalParser.generate_response_message("allow_once", nil)
      assert.is_not_nil(message:match("tool"))
    end)

    it("should return unknown for invalid action", function()
      local message = ApprovalParser.generate_response_message("invalid", "Tool")
      assert.is_not_nil(message:match("Unknown"))
    end)
  end)
end)
