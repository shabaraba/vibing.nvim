-- 見つけたセッションの開き方。resume は CLI ごとのセッション ID と git ルート内の working_dir に
-- 縛られるので、それを満たさないものは開かずに理由を言い、引き継ぎを勧める。
local MODULE = "vibing.presentation.chat.modules.session_opener"

describe("session opener", function()
  local SessionOpener
  local created, rendered, render_buf

  ---@param overrides table?
  ---@return Vibing.Session.Search.Result
  local function result(overrides)
    return vim.tbl_extend("force", {
      backend = "claude",
      session_id = "abc",
      cwd = vim.fn.getcwd(),
      updated_at = "",
      title = "",
      summary = "",
      group = "",
    }, overrides or {})
  end

  before_each(function()
    created, rendered = {}, {}
    render_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(render_buf, 0, -1, false, { "## User <!-- unsent -->", "" })

    package.loaded["vibing"] = {
      get_config = function()
        return { adapter = "claude" }
      end,
    }
    package.loaded["vibing.application.chat.use_case"] = {
      create_new = function(opts)
        local session = { opts = opts or {}, frontmatter = {} }
        function session:update_session_id(id)
          self.session_id = id
        end
        function session:update_frontmatter(key, value)
          self.frontmatter[key] = value
        end
        created[#created + 1] = session
        return session
      end,
    }
    package.loaded["vibing.presentation.chat.view"] = {
      render = function(session)
        rendered[#rendered + 1] = session
        return { buf = render_buf }
      end,
    }
    package.loaded[MODULE] = nil
    SessionOpener = require(MODULE)
  end)

  after_each(function()
    package.loaded["vibing"] = nil
    package.loaded["vibing.application.chat.use_case"] = nil
    package.loaded["vibing.presentation.chat.view"] = nil
    package.loaded[MODULE] = nil
    vim.api.nvim_buf_delete(render_buf, { force = true })
  end)

  describe("resume_target", function()
    it("resolves a session of this CLI inside this repository", function()
      assert.are.equal(".", SessionOpener.resume_target(result()))
    end)

    it("refuses a session of another CLI", function()
      local working_dir, reason = SessionOpener.resume_target(result({ backend = "codex" }))

      assert.is_nil(working_dir)
      assert.is_truthy(reason:find("codex", 1, true))
    end)

    it("refuses a session outside this repository", function()
      local outside = vim.fn.tempname()
      vim.fn.mkdir(outside, "p")

      local working_dir, reason = SessionOpener.resume_target(result({ cwd = outside }))

      assert.is_nil(working_dir)
      assert.is_truthy(reason:find("outside", 1, true))
      vim.fn.delete(outside, "rf")
    end)

    it("refuses a session whose directory is unknown or gone", function()
      local unknown = result()
      unknown.cwd = nil
      assert.is_nil(SessionOpener.resume_target(unknown))
      assert.is_nil(SessionOpener.resume_target(result({ cwd = vim.fn.tempname() })))
    end)
  end)

  describe("resume", function()
    it("opens a chat that carries the session, the CLI and the directory", function()
      assert.is_true(SessionOpener.resume(result()))

      assert.are.equal(1, #rendered)
      assert.are.equal("abc", created[1].session_id)
      assert.are.equal("claude", created[1].frontmatter.agent)
      assert.are.equal(".", created[1].opts.working_dir)
    end)

    it("opens nothing for a session it cannot resume", function()
      assert.is_false(SessionOpener.resume(result({ backend = "codex" })))
      assert.are.same({}, rendered)
    end)
  end)

  describe("handoff", function()
    it("drafts the request into a fresh chat, for any CLI", function()
      assert.is_true(SessionOpener.handoff(result({ backend = "codex", cwd = "/elsewhere" })))

      assert.is_nil(created[1].session_id)
      local lines = vim.api.nvim_buf_get_lines(render_buf, 0, -1, false)
      assert.are.equal("## User <!-- unsent -->", lines[1])
      local draft = lines[#lines]
      assert.is_truthy(draft:find("codex session abc", 1, true))
      assert.is_truthy(draft:find("/elsewhere", 1, true))
      assert.is_truthy(draft:find("nvim_session_read", 1, true))
    end)
  end)
end)
