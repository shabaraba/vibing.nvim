local frontmatter = require("vibing.infrastructure.storage.frontmatter")

describe("frontmatter", function()
  describe("parse valid YAML (UT-FM-001)", function()
    it("should parse basic frontmatter", function()
      local content = [[---
vibing.nvim: true
session_id: abc123
created_at: 2024-01-01T12:00:00
mode: code
model: sonnet
---
Hello world]]

      local result, body = frontmatter.parse(content)
      assert.is_not_nil(result)
      assert.equals("abc123", result.session_id)
      assert.equals("code", result.mode)
      assert.equals("sonnet", result.model)
      assert.equals("Hello world", body:gsub("^%s*", ""))
    end)

    it("should parse frontmatter with boolean values", function()
      local content = [[---
vibing.nvim: true
enabled: false
---]]

      local result = frontmatter.parse(content)
      -- parse_yaml_value converts "true"/"false" to boolean values
      assert.equals(true, result["vibing.nvim"])
      assert.equals(false, result.enabled)
    end)
  end)

  describe("parse permissions (UT-FM-002)", function()
    it("should parse permission arrays", function()
      local content = [[---
permissions_mode: acceptEdits
permissions_allow:
  - Read
  - Edit
  - Write
permissions_deny:
  - Bash
---]]

      local result = frontmatter.parse(content)
      assert.equals("acceptEdits", result.permissions_mode)
      assert.is_table(result.permissions_allow)
      assert.equals(3, #result.permissions_allow)
      assert.equals("Read", result.permissions_allow[1])
      assert.equals("Bash", result.permissions_deny[1])
    end)

    it("should handle empty permission arrays", function()
      local content = [[---
permissions_allow:
permissions_deny:
---]]

      local result = frontmatter.parse(content)
      assert.is_not_nil(result)
    end)
  end)

  describe("handle invalid YAML (UT-FM-003)", function()
    it("should return nil for content without frontmatter", function()
      local content = "no frontmatter here"
      local result = frontmatter.parse(content)
      assert.is_nil(result)
    end)

    it("should return empty table for empty frontmatter", function()
      local content = [[---
---
body content]]

      local result, body = frontmatter.parse(content)
      assert.is_table(result)
      assert.equals(0, vim.tbl_count(result))
    end)

    it("should handle missing end delimiter gracefully", function()
      local content = [[---
key: value
no closing delimiter]]

      local result = frontmatter.parse(content)
      assert.is_nil(result)
    end)
  end)

  describe("serialize to YAML (UT-FM-004)", function()
    it("should serialize basic data", function()
      local data = {
        ["vibing.nvim"] = true,
        session_id = "abc123",
        mode = "code",
      }

      local result = frontmatter.serialize(data, "body content")
      assert.is_string(result)
      assert.is_not_nil(result:match("vibing.nvim: true"))
      assert.is_not_nil(result:match("session_id: abc123"))
      assert.is_not_nil(result:match("mode: code"))
    end)

    it("should serialize arrays correctly", function()
      local data = {
        permissions_allow = { "Read", "Edit" },
      }

      local result = frontmatter.serialize(data, "")
      assert.is_string(result)
      assert.is_not_nil(result:match("permissions_allow:"))
      assert.is_not_nil(result:match("  %- Read"))
      assert.is_not_nil(result:match("  %- Edit"))
    end)

    it("should preserve body content", function()
      local data = { key = "value" }
      local body = "## User\n\nHello world"

      local result = frontmatter.serialize(data, body)
      assert.is_not_nil(result:match("Hello world"))
    end)
  end)

  describe("roundtrip", function()
    it("should parse what it serializes", function()
      local original = {
        ["vibing.nvim"] = true,
        session_id = "test123",
        mode = "code",
        model = "sonnet",
      }
      local body = "Test body"

      local serialized = frontmatter.serialize(original, body)
      local parsed, parsed_body = frontmatter.parse(serialized)

      assert.equals(original.session_id, parsed.session_id)
      assert.equals(original.mode, parsed.mode)
      assert.equals(original.model, parsed.model)
    end)
  end)
end)
