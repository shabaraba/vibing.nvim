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

  -- `generate_response_message` の describe はここにあった。本番コードからの参照が無い関数を、
  -- この spec だけが緑に保っていた — しかも中身は `approval_decision.retry_message` とは別の
  -- 文面の、承認の意味の2つ目の実装。#778 で関数ごと消した。
end)
