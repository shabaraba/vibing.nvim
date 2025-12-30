local Message = require("vibing.domain.chat.message")

describe("Message", function()
  describe("new (UT-MSG-001)", function()
    it("should create a user message", function()
      local msg = Message.new("user", "Hello world")

      assert.equals("user", msg.role)
      assert.equals("Hello world", msg.content)
      assert.is_not_nil(msg.timestamp)
    end)

    it("should create an assistant message", function()
      local msg = Message.new("assistant", "Hi there!")

      assert.equals("assistant", msg.role)
      assert.equals("Hi there!", msg.content)
    end)

    it("should use provided timestamp", function()
      local ts = "2024-01-01 12:00:00"
      local msg = Message.new("user", "Test", ts)

      assert.equals(ts, msg.timestamp)
    end)

    it("should generate timestamp if not provided", function()
      local msg = Message.new("user", "Test")

      assert.is_string(msg.timestamp)
      assert.is_not_nil(msg.timestamp:match("%d%d%d%d%-%d%d%-%d%d"))
    end)
  end)

  describe("invalid role (UT-MSG-002)", function()
    it("should reject invalid role", function()
      assert.has_error(function()
        local msg = Message.new("invalid", "Test")
        msg:validate()
      end)
    end)

    it("should reject nil role", function()
      assert.has_error(function()
        local msg = Message.new(nil, "Test")
        msg:validate()
      end)
    end)

    it("should reject empty role", function()
      assert.has_error(function()
        local msg = Message.new("", "Test")
        msg:validate()
      end)
    end)
  end)

  describe("to_header", function()
    it("should format user header correctly", function()
      local msg = Message.new("user", "Test", "2024-01-01 12:00:00")
      local header = msg:to_header()

      assert.is_not_nil(header:match("2024%-01%-01 12:00:00"))
      assert.is_not_nil(header:match("User"))
    end)

    it("should format assistant header correctly", function()
      local msg = Message.new("assistant", "Test", "2024-01-01 12:00:00")
      local header = msg:to_header()

      assert.is_not_nil(header:match("Assistant"))
    end)
  end)

  describe("to_markdown", function()
    it("should include header and content", function()
      local msg = Message.new("user", "Hello world", "2024-01-01 12:00:00")
      local md = msg:to_markdown()

      assert.is_not_nil(md:match("## "))
      assert.is_not_nil(md:match("Hello world"))
    end)
  end)

  describe("validate", function()
    it("should pass for valid user message", function()
      local msg = Message.new("user", "Valid content")
      assert.is_true(msg:validate())
    end)

    it("should pass for valid assistant message", function()
      local msg = Message.new("assistant", "Valid content")
      assert.is_true(msg:validate())
    end)

    it("should fail for non-string content", function()
      assert.has_error(function()
        local msg = Message.new("user", 123)
        msg:validate()
      end)
    end)
  end)
end)
