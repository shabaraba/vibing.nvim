---Security module tests
---Tests for path_sanitizer and command_validator modules

local PathSanitizer = require("vibing.domain.security.path_sanitizer")
local CommandValidator = require("vibing.domain.security.command_validator")

describe("PathSanitizer", function()
  describe("normalize", function()
    it("should normalize a simple path", function()
      local normalized, err = PathSanitizer.normalize("/tmp/test.txt")
      assert.is_not_nil(normalized)
      assert.is_nil(err)
      assert.is_not_nil(normalized:match("^/"))  -- Should be absolute
    end)

    it("should expand ~ in paths", function()
      local normalized, err = PathSanitizer.normalize("~/test.txt")
      assert.is_not_nil(normalized)
      assert.is_nil(err)
      assert.is_not_nil(normalized:match("^/"))  -- Should be absolute
      assert.is_nil(normalized:match("~"))  -- ~ should be expanded
    end)

    it("should reject empty paths", function()
      local normalized, err = PathSanitizer.normalize("")
      assert.is_nil(normalized)
      assert.equals("Empty path", err)
    end)

    it("should reject nil paths", function()
      local normalized, err = PathSanitizer.normalize(nil)
      assert.is_nil(normalized)
      assert.equals("Empty path", err)
    end)
  end)

  describe("check_traversal_patterns", function()
    it("should detect ../ pattern", function()
      local valid, err = PathSanitizer.check_traversal_patterns("../etc/passwd")
      assert.is_false(valid)
      assert.is_not_nil(err)
    end)

    it("should detect ../../ pattern", function()
      local valid, err = PathSanitizer.check_traversal_patterns("/tmp/../../etc/passwd")
      assert.is_false(valid)
      assert.is_not_nil(err)
    end)

    it("should allow safe paths", function()
      local valid, err = PathSanitizer.check_traversal_patterns("/tmp/test.txt")
      assert.is_true(valid)
      assert.is_nil(err)
    end)

    it("should allow paths with dots in filenames", function()
      local valid, err = PathSanitizer.check_traversal_patterns("/tmp/file.with.dots.txt")
      assert.is_true(valid)
      assert.is_nil(err)
    end)
  end)

  describe("validate_within_roots", function()
    it("should allow path within allowed root", function()
      local valid, err = PathSanitizer.validate_within_roots(
        "/tmp/test/file.txt",
        { "/tmp" }
      )
      assert.is_true(valid)
      assert.is_nil(err)
    end)

    it("should reject path outside allowed roots", function()
      local valid, err = PathSanitizer.validate_within_roots(
        "/etc/passwd",
        { "/tmp", "/home" }
      )
      assert.is_false(valid)
      assert.is_not_nil(err)
    end)

    it("should allow all paths when no roots specified", function()
      local valid, err = PathSanitizer.validate_within_roots("/etc/passwd", {})
      assert.is_true(valid)
      assert.is_nil(err)
    end)
  end)

  describe("sanitize", function()
    it("should sanitize and normalize safe paths", function()
      local sanitized, err = PathSanitizer.sanitize("/tmp/test.txt")
      assert.is_not_nil(sanitized)
      assert.is_nil(err)
    end)

    it("should reject paths with traversal patterns", function()
      local sanitized, err = PathSanitizer.sanitize("../etc/passwd")
      assert.is_nil(sanitized)
      assert.is_not_nil(err)
    end)

    it("should reject paths outside allowed roots", function()
      local sanitized, err = PathSanitizer.sanitize(
        "/etc/passwd",
        { "/tmp", "/home" }
      )
      assert.is_nil(sanitized)
      assert.is_not_nil(err)
    end)
  end)
end)

describe("CommandValidator", function()
  describe("contains_metacharacters", function()
    it("should detect semicolon", function()
      local has_meta, char = CommandValidator.contains_metacharacters("ls; rm -rf /")
      assert.is_true(has_meta)
      assert.equals(";", char)
    end)

    it("should detect pipe", function()
      local has_meta, char = CommandValidator.contains_metacharacters("cat file | sh")
      assert.is_true(has_meta)
      assert.equals("|", char)
    end)

    it("should detect command substitution", function()
      local has_meta, char = CommandValidator.contains_metacharacters("echo `whoami`")
      assert.is_true(has_meta)
      assert.equals("`", char)
    end)

    it("should allow safe commands", function()
      local has_meta, char = CommandValidator.contains_metacharacters("ls -la")
      assert.is_false(has_meta)
      assert.is_nil(char)
    end)
  end)

  describe("matches_dangerous_pattern", function()
    it("should detect rm -rf", function()
      local dangerous, pattern = CommandValidator.matches_dangerous_pattern("rm -rf /")
      assert.is_true(dangerous)
      assert.is_not_nil(pattern)
    end)

    it("should detect sudo", function()
      local dangerous, pattern = CommandValidator.matches_dangerous_pattern("sudo rm file")
      assert.is_true(dangerous)
      assert.is_not_nil(pattern)
    end)

    it("should detect dd", function()
      local dangerous, pattern = CommandValidator.matches_dangerous_pattern("dd if=/dev/zero of=/dev/sda")
      assert.is_true(dangerous)
      assert.is_not_nil(pattern)
    end)

    it("should allow safe commands", function()
      local dangerous, pattern = CommandValidator.matches_dangerous_pattern("ls -la")
      assert.is_false(dangerous)
      assert.is_nil(pattern)
    end)
  end)

  describe("validate_command", function()
    it("should validate safe commands", function()
      local valid, err = CommandValidator.validate_command("ls")
      assert.is_true(valid)
      assert.is_nil(err)
    end)

    it("should reject commands with metacharacters", function()
      local valid, err = CommandValidator.validate_command("ls; rm -rf")
      assert.is_false(valid)
      assert.is_not_nil(err)
    end)

    it("should reject dangerous commands", function()
      local valid, err = CommandValidator.validate_command("sudo rm")
      assert.is_false(valid)
      assert.is_not_nil(err)
    end)

    it("should reject empty commands", function()
      local valid, err = CommandValidator.validate_command("")
      assert.is_false(valid)
      assert.equals("Empty command", err)
    end)
  end)

  describe("validate_arguments", function()
    it("should validate safe arguments", function()
      local valid, err = CommandValidator.validate_arguments({ "-la", "/tmp" })
      assert.is_true(valid)
      assert.is_nil(err)
    end)

    it("should reject arguments with metacharacters", function()
      local valid, err = CommandValidator.validate_arguments({ "-la", "; rm -rf /" })
      assert.is_false(valid)
      assert.is_not_nil(err)
    end)

    it("should allow nil arguments", function()
      local valid, err = CommandValidator.validate_arguments(nil)
      assert.is_true(valid)
      assert.is_nil(err)
    end)
  end)

  describe("validate_full_command", function()
    it("should validate safe command with arguments", function()
      local valid, err = CommandValidator.validate_full_command("ls", { "-la", "/tmp" })
      assert.is_true(valid)
      assert.is_nil(err)
    end)

    it("should reject dangerous command", function()
      local valid, err = CommandValidator.validate_full_command("sudo", { "rm", "-rf" })
      assert.is_false(valid)
      assert.is_not_nil(err)
    end)

    it("should reject command with malicious arguments", function()
      local valid, err = CommandValidator.validate_full_command("echo", { "; rm -rf /" })
      assert.is_false(valid)
      assert.is_not_nil(err)
    end)
  end)

  describe("is_allowed_command", function()
    it("should allow whitelisted commands", function()
      local allowed = CommandValidator.is_allowed_command("git", { "git", "npm", "yarn" })
      assert.is_true(allowed)
    end)

    it("should reject non-whitelisted commands", function()
      local allowed = CommandValidator.is_allowed_command("rm", { "git", "npm", "yarn" })
      assert.is_false(allowed)
    end)

    it("should allow all when no whitelist provided", function()
      local allowed = CommandValidator.is_allowed_command("any-command", {})
      assert.is_true(allowed)
    end)
  end)

  describe("escape_for_shell", function()
    it("should escape single quotes", function()
      local escaped = CommandValidator.escape_for_shell("it's a test")
      assert.equals("'it'\"'\"'s a test'", escaped)
    end)

    it("should wrap in single quotes", function()
      local escaped = CommandValidator.escape_for_shell("test")
      assert.equals("'test'", escaped)
    end)

    it("should handle empty string", function()
      local escaped = CommandValidator.escape_for_shell("")
      assert.equals("", escaped)
    end)
  end)
end)
