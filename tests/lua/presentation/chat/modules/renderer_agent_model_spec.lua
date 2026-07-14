describe("renderer.init_content agent/model defaults", function()
  local Renderer
  local vibing_stub

  before_each(function()
    package.loaded["vibing.presentation.chat.modules.renderer"] = nil
    package.loaded["vibing"] = nil

    vibing_stub = {
      get_config = function()
        return {
          adapter = "grok",
          agent = { default_model = "sonnet" },
          permissions = {
            mode = "acceptEdits",
            allow = { "Read" },
            deny = { "Bash" },
            ask = {},
          },
        }
      end,
    }
    package.loaded["vibing"] = vibing_stub
    package.loaded["vibing.application.context.manager"] = {
      format_for_display = function()
        return "(none)"
      end,
    }
    package.loaded["vibing.core.utils.timestamp"] = {
      create_unsent_user_header = function()
        return "## User <!-- unsent -->"
      end,
    }

    Renderer = require("vibing.presentation.chat.modules.renderer")
  end)

  after_each(function()
    package.loaded["vibing.presentation.chat.modules.renderer"] = nil
    package.loaded["vibing"] = nil
  end)

  it("writes agent: grok and model: grok-4.5 when adapter is grok (not sonnet)", function()
    local buf = vim.api.nvim_create_buf(false, true)
    Renderer.init_content(buf, nil)
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local text = table.concat(lines, "\n")

    assert.is_truthy(text:find("agent: grok", 1, true))
    assert.is_truthy(text:find("model: grok-4.5", 1, true))
    assert.is_nil(text:find("model: sonnet", 1, true))

    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("keeps an explicit non-Claude model from session frontmatter", function()
    local buf = vim.api.nvim_create_buf(false, true)
    Renderer.init_content(buf, {
      frontmatter = {
        agent = "grok",
        model = "grok-composer-2.5-fast",
      },
    })
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local text = table.concat(lines, "\n")

    assert.is_truthy(text:find("model: grok-composer-2.5-fast", 1, true))

    vim.api.nvim_buf_delete(buf, { force = true })
  end)
end)
