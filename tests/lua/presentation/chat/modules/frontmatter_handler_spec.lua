-- Tests for vibing.presentation.chat.modules.frontmatter_handler

local handler = require("vibing.presentation.chat.modules.frontmatter_handler")

describe("frontmatter_handler.update_field", function()
  local buf

  ---@param lines string[]
  local function open(lines)
    buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    return buf
  end

  ---@return string[]
  local function frontmatter_lines()
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local out = {}
    for i = 2, #lines do
      if lines[i] == "---" then
        break
      end
      table.insert(out, lines[i])
    end
    return out
  end

  after_each(function()
    if buf and vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_delete(buf, { force = true })
    end
  end)

  it("replaces an existing line for the same key", function()
    open({ "---", "permission_mode: default", "---", "" })

    assert.is_true(handler.update_field(buf, "permission_mode", "plan", false))
    assert.same({ "permission_mode: plan" }, frontmatter_lines())
  end)

  it("appends the key when the frontmatter does not have it yet", function()
    open({ "---", "session_id: abc", "---", "" })

    assert.is_true(handler.update_field(buf, "permission_mode", "plan", false))
    assert.same({ "session_id: abc", "permission_mode: plan" }, frontmatter_lines())
  end)

  it("collapses a file that already carries both spellings", function()
    -- Before this branch, /permission appended the canonical key next to the legacy one, so
    -- files with both lines exist in the wild. Writing the key has to leave exactly one.
    open({ "---", "permissions_mode: default", "session_id: abc", "permission_mode: plan", "---", "" })

    assert.is_true(handler.update_field(buf, "permission_mode", "acceptEdits", false))
    assert.same({ "permission_mode: acceptEdits", "session_id: abc" }, frontmatter_lines())
  end)

  it("rewrites a legacy plural line in place instead of adding a duplicate", function()
    -- A chat written against the old README. Writing the canonical key must not leave the file
    -- carrying the same setting twice under two spellings.
    open({ "---", "permissions_mode: default", "---", "" })

    assert.is_true(handler.update_field(buf, "permission_mode", "plan", false))
    assert.same({ "permission_mode: plan" }, frontmatter_lines())
  end)
end)

describe("frontmatter_handler.update_list", function()
  local buf

  ---@param lines string[]
  local function open(lines)
    buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    return buf
  end

  ---frontmatter の中身から `updated_at` を除いて返す。update_list は毎回それを打つので、
  ---どのアサーションにも現れて本題を隠してしまう
  ---@return string[]
  local function frontmatter_lines()
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local out = {}
    for i = 2, #lines do
      if lines[i] == "---" then
        break
      end
      if not lines[i]:match("^updated_at:") then
        table.insert(out, lines[i])
      end
    end
    return out
  end

  after_each(function()
    if buf and vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_delete(buf, { force = true })
    end
  end)

  it("creates the key block when the frontmatter does not have it yet", function()
    open({ "---", "session_id: abc", "---", "" })

    assert.is_true(handler.update_list(buf, "orchestrated", "chat/worker.md", "add"))
    assert.same({ "session_id: abc", "orchestrated:", "  - chat/worker.md" }, frontmatter_lines())
  end)

  it("appends to an existing list", function()
    open({ "---", "orchestrated:", "  - chat/a.md", "---", "" })

    assert.is_true(handler.update_list(buf, "orchestrated", "chat/b.md", "add"))
    assert.same({ "orchestrated:", "  - chat/a.md", "  - chat/b.md" }, frontmatter_lines())
  end)

  it("does not add a value the list already carries", function()
    open({ "---", "orchestrated:", "  - chat/a.md", "---", "" })

    assert.is_true(handler.update_list(buf, "orchestrated", "chat/a.md", "add"))
    assert.same({ "orchestrated:", "  - chat/a.md" }, frontmatter_lines())
  end)

  it("dedupes on the exact string only", function()
    -- 同じファイルを git 相対と ~ 短縮の両方で書くと、両方が残る。書き込む側が
    -- `Git.to_display_path` に一本化している前提の上に成り立っている
    open({ "---", "orchestrated:", "  - chat/a.md", "---", "" })

    handler.update_list(buf, "orchestrated", "~/proj/chat/a.md", "add")
    assert.same({ "orchestrated:", "  - chat/a.md", "  - ~/proj/chat/a.md" }, frontmatter_lines())
  end)

  it("removes one item and keeps the others", function()
    open({ "---", "orchestrated:", "  - chat/a.md", "  - chat/b.md", "---", "" })

    assert.is_true(handler.update_list(buf, "orchestrated", "chat/a.md", "remove"))
    assert.same({ "orchestrated:", "  - chat/b.md" }, frontmatter_lines())
  end)

  it("drops the key entirely when the last item is removed", function()
    open({ "---", "session_id: abc", "orchestrated:", "  - chat/a.md", "---", "" })

    assert.is_true(handler.update_list(buf, "orchestrated", "chat/a.md", "remove"))
    assert.same({ "session_id: abc" }, frontmatter_lines())
  end)

  it("keeps a neighbouring key intact when the list is rewritten", function()
    open({ "---", "orchestrated:", "  - chat/a.md", "model: sonnet", "---", "" })

    assert.is_true(handler.update_list(buf, "orchestrated", "chat/b.md", "add"))
    assert.same({ "orchestrated:", "  - chat/a.md", "  - chat/b.md", "model: sonnet" }, frontmatter_lines())
  end)

  it("refuses an empty key or value instead of writing a malformed line", function()
    open({ "---", "session_id: abc", "---", "" })

    assert.is_false(handler.update_list(buf, "orchestrated", "", "add"))
    assert.is_false(handler.update_list(buf, "", "chat/a.md", "add"))
    assert.same({ "session_id: abc" }, frontmatter_lines())
  end)

  it("returns false when the frontmatter has no closing delimiter", function()
    open({ "---", "session_id: abc", "" })

    assert.is_false(handler.update_list(buf, "orchestrated", "chat/a.md", "add"))
  end)
end)

describe("frontmatter_handler reads to the closing delimiter", function()
  -- Each of these functions used to read a fixed window (100 lines, and 10 for
  -- update_session_id) and fail silently past it. A chat's frontmatter has no
  -- length bound: permission and orchestration lists grow with use.
  local buf

  ---frontmatterの前半を150行のリストで埋め、`tail`を窓の外に押し出す
  ---@param tail string[]
  local function open_with_long_head(tail)
    local lines = { "---", "permissions_allow:" }
    for i = 1, 150 do
      table.insert(lines, "  - perm" .. i)
    end
    vim.list_extend(lines, tail)
    table.insert(lines, "---")
    table.insert(lines, "# Vibing Chat")

    buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    return buf
  end

  ---埋め草(`  - permN`)と`updated_at`を除いたfrontmatterの中身
  ---@return string[]
  local function significant_lines()
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local out = {}
    for i = 2, #lines do
      if lines[i] == "---" then
        break
      end
      if not lines[i]:match("^  %- perm%d+$") and not lines[i]:match("^updated_at:") then
        table.insert(out, lines[i])
      end
    end
    return out
  end

  after_each(function()
    if buf and vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_delete(buf, { force = true })
    end
  end)

  it("update_session_id rewrites a line far past the old 10-line window", function()
    open_with_long_head({ "session_id: old" })

    handler.update_session_id(buf, "new-session")
    assert.same({ "permissions_allow:", "session_id: new-session" }, significant_lines())
  end)

  it("update_field replaces a key far past the old window", function()
    open_with_long_head({ "permission_mode: default" })

    assert.is_true(handler.update_field(buf, "permission_mode", "plan", false))
    assert.same({ "permissions_allow:", "permission_mode: plan" }, significant_lines())
  end)

  it("update_field appends into a frontmatter longer than the old window", function()
    open_with_long_head({ "session_id: abc" })

    assert.is_true(handler.update_field(buf, "model", "opus", false))
    assert.same({ "permissions_allow:", "session_id: abc", "model: opus" }, significant_lines())
  end)

  it("update_list appends to a list far past the old window", function()
    open_with_long_head({ "orchestrated:", "  - chat/a.md" })

    assert.is_true(handler.update_list(buf, "orchestrated", "chat/b.md", "add"))
    assert.same({
      "permissions_allow:",
      "orchestrated:",
      "  - chat/a.md",
      "  - chat/b.md",
    }, significant_lines())
  end)

  it("update_list keeps the long list it is not targeting intact", function()
    -- The filler *is* a list here, so a mis-scoped rewrite would eat it.
    open_with_long_head({ "session_id: abc" })

    assert.is_true(handler.update_list(buf, "orchestrated", "chat/a.md", "add"))
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local perms = 0
    for _, line in ipairs(lines) do
      if line:match("^  %- perm%d+$") then
        perms = perms + 1
      end
    end
    assert.equals(150, perms)
  end)

  it("parse reads a key far past the old window", function()
    open_with_long_head({ "model: opus", "language: ja" })

    local parsed = handler.parse(buf)
    assert.equals("opus", parsed.model)
    assert.equals("ja", parsed.language)
    assert.equals(150, #parsed.permissions_allow)
  end)

  it("does nothing when the frontmatter never closes", function()
    buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "---", "session_id: old" })

    handler.update_session_id(buf, "new-session")
    assert.is_false(handler.update_field(buf, "model", "opus", false))
    assert.is_false(handler.update_list(buf, "orchestrated", "chat/a.md", "add"))
    assert.same({}, handler.parse(buf))
    assert.same({ "---", "session_id: old" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
  end)
end)
