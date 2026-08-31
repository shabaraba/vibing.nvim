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
permission_mode: acceptEdits
permissions_allow:
  - Read
  - Edit
  - Write
permissions_deny:
  - Bash
---]]

      local result = frontmatter.parse(content)
      assert.equals("acceptEdits", result.permission_mode)
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

    it("should migrate the legacy plural permissions_mode to permission_mode", function()
      local content = [[---
permissions_mode: plan
---]]

      local result = frontmatter.parse(content)
      assert.equals("plan", result.permission_mode)
      assert.is_nil(result.permissions_mode)
    end)

    it("should prefer the singular permission_mode when both keys are present", function()
      local content = [[---
permission_mode: acceptEdits
permissions_mode: plan
---]]

      local result = frontmatter.parse(content)
      assert.equals("acceptEdits", result.permission_mode)
      assert.is_nil(result.permissions_mode)
    end)

    it("should not let update() write the legacy plural key back out", function()
      local content = [[---
session_id: abc
---]]

      local updated = frontmatter.update(content, { permissions_mode = "plan" })
      assert.is_truthy(updated:find("permission_mode: plan", 1, true))
      assert.is_nil(updated:find("permissions_mode:", 1, true))
    end)

    it("should serialize permission_mode before the permissions lists", function()
      local serialized = frontmatter.serialize({
        language = "ja",
        permissions_allow = { "Read" },
        permission_mode = "acceptEdits",
        session_id = "abc",
      })
      local lines = vim.split(serialized, "\n", { plain = true })
      local order = {}
      for _, line in ipairs(lines) do
        local key = line:match("^([%w_%.]+):")
        if key then
          table.insert(order, key)
        end
      end
      assert.same({ "session_id", "permission_mode", "permissions_allow", "language" }, order)
    end)

    it("should serialize the orchestration links beside the other origin fields", function()
      -- `forked_from` / `subagent_id` と同じく「このチャットが他のどれと繋がっているか」を
      -- 答えるフィールドなので、設定値より前にまとまって並ぶ
      local serialized = frontmatter.serialize({
        language = "ja",
        orchestrated_by = { "chat/a.md" },
        working_dir = ".vibing/worktrees/x",
        orchestrated = { "chat/b.md" },
        forked_from = "chat/c.md",
        session_id = "abc",
      })
      local order = {}
      for _, line in ipairs(vim.split(serialized, "\n", { plain = true })) do
        local key = line:match("^([%w_%.]+):")
        if key then
          table.insert(order, key)
        end
      end
      assert.same({
        "session_id",
        "forked_from",
        "orchestrated",
        "orchestrated_by",
        "working_dir",
        "language",
      }, order)
    end)

    it("should round-trip an empty list as a truthy but empty table", function()
      -- 空リストは値なしの `orchestrated:` 行になり、パースすると `{}` に戻る。真値なので
      -- `if not value` では弾けず、読む側は `#value == 0` を見る必要がある
      local serialized = frontmatter.serialize({ ["vibing.nvim"] = true, orchestrated = {} })
      local parsed = frontmatter.parse(serialized)

      assert.is_table(parsed.orchestrated)
      assert.equals(0, #parsed.orchestrated)
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

  -- Build a chat frontmatter whose closing `---` sits after `filler` array items.
  local function chat_lines(filler)
    local lines = { "---", "vibing.nvim: true", "permissions_allow:" }
    for i = 1, filler do
      table.insert(lines, "  - perm" .. i)
    end
    table.insert(lines, "---")
    table.insert(lines, "# Vibing Chat")
    return lines
  end

  describe("is_vibing_chat_file", function()
    local tmpdir
    local created = {}

    before_each(function()
      tmpdir = vim.fn.tempname()
      vim.fn.mkdir(tmpdir, "p")
    end)

    after_each(function()
      for _, path in ipairs(created) do
        vim.fn.delete(path)
      end
      created = {}
      vim.fn.delete(tmpdir, "rf")
    end)

    local function write_file(lines)
      local path = tmpdir .. "/" .. tostring(#created) .. ".md"
      vim.fn.writefile(lines, path)
      table.insert(created, path)
      return path
    end

    it("detects a chat whose frontmatter closes past any fixed window", function()
      -- The scan follows the frontmatter to its close, so no line count -- 50,
      -- 200, or otherwise -- is the boundary between chat and not-a-chat.
      assert.is_true(frontmatter.is_vibing_chat_file(write_file(chat_lines(400))))
    end)

    it("detects an ordinary short chat", function()
      assert.is_true(frontmatter.is_vibing_chat_file(write_file({ "---", "vibing.nvim: true", "---", "body" })))
    end)

    it("rejects a frontmatter that never closes", function()
      assert.is_false(frontmatter.is_vibing_chat_file(write_file({ "---", "vibing.nvim: true" })))
    end)

    it("rejects a file whose frontmatter lacks the marker", function()
      assert.is_false(frontmatter.is_vibing_chat_file(write_file({ "---", "title: notes", "---", "body" })))
    end)

    it("rejects a file that does not open with a frontmatter", function()
      assert.is_false(frontmatter.is_vibing_chat_file(write_file({ "# notes", "vibing.nvim: true" })))
    end)

    it("does not read the marker from the body", function()
      -- Past the closing `---` the file is prose, and prose that happens to name
      -- the key is not a chat.
      local path = write_file({ "---", "title: notes", "---", "vibing.nvim: true" })
      assert.is_false(frontmatter.is_vibing_chat_file(path))
    end)

    it("rejects a missing file", function()
      assert.is_false(frontmatter.is_vibing_chat_file(tmpdir .. "/absent.md"))
    end)
  end)

  describe("buffer_region", function()
    local function make_buf(lines)
      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
      return buf
    end

    it("returns the frontmatter with both delimiters and nothing else", function()
      -- The index of each returned line is its buffer line number, which is what
      -- lets frontmatter_handler edit lines by that index.
      local region = frontmatter.buffer_region(make_buf({
        "---",
        "vibing.nvim: true",
        "---",
        "# Vibing Chat",
        "---",
      }))

      assert.same({ "---", "vibing.nvim: true", "---" }, region)
    end)

    it("follows a frontmatter longer than any fixed window", function()
      local region = frontmatter.buffer_region(make_buf(chat_lines(400)))

      assert.equals(404, #region)
      assert.equals("---", region[#region])
    end)

    it("returns nil when the frontmatter never closes", function()
      assert.is_nil(frontmatter.buffer_region(make_buf({ "---", "vibing.nvim: true" })))
    end)

    it("returns nil when the buffer does not open with a frontmatter", function()
      assert.is_nil(frontmatter.buffer_region(make_buf({ "# notes", "---", "key: value", "---" })))
    end)

    it("returns nil for an empty buffer", function()
      assert.is_nil(frontmatter.buffer_region(make_buf({})))
    end)

    it("returns nil for an invalid buffer", function()
      assert.is_nil(frontmatter.buffer_region(999999))
      assert.is_nil(frontmatter.buffer_region(nil))
    end)
  end)

  describe("is_vibing_chat_buffer (UT-FM-005)", function()
    local function make_buf(lines)
      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
      return buf
    end

    it("detects a chat buffer whose frontmatter closes past line 50", function()
      -- Long permission arrays (e.g. codex sessions) push the closing `---`
      -- well past line 50; the buffer check must still recognize it.
      local buf = make_buf(chat_lines(80))
      assert.is_true(frontmatter.is_vibing_chat_buffer(buf))
    end)

    it("detects a chat buffer whose frontmatter closes past any fixed window", function()
      assert.is_true(frontmatter.is_vibing_chat_buffer(make_buf(chat_lines(400))))
    end)

    it("reads across chunk boundaries", function()
      -- The buffer is fed to the scanner in fixed-size chunks; a closing `---`
      -- landing on or next to a boundary must not be skipped or re-read.
      for _, filler in ipairs({ 60, 61, 62, 63, 64, 65, 126, 127, 128, 129 }) do
        assert.is_true(frontmatter.is_vibing_chat_buffer(make_buf(chat_lines(filler))))
      end
    end)

    it("does not stick a negative result while content is still incomplete", function()
      -- A buffer mid-stream (frontmatter not yet closed) must not cache `false`,
      -- otherwise it stays unrecognized forever once the content completes.
      local buf = make_buf({ "---", "vibing.nvim: true" })
      assert.is_false(frontmatter.is_vibing_chat_buffer(buf))
      assert.is_nil(vim.b[buf].vibing_is_chat_buffer)

      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "---", "vibing.nvim: true", "---", "# Vibing Chat" })
      assert.is_true(frontmatter.is_vibing_chat_buffer(buf))
      assert.is_true(vim.b[buf].vibing_is_chat_buffer)
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
