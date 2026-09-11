local Renderer = require("vibing.presentation.chat.modules.renderer")

describe("chat renderer frontmatter", function()
  local bufnr

  before_each(function()
    require("vibing").setup()
    bufnr = vim.api.nvim_create_buf(false, true)
  end)

  after_each(function()
    if vim.api.nvim_buf_is_valid(bufnr) then
      vim.api.nvim_buf_delete(bufnr, { force = true })
    end
  end)

  it("shows effort: default in a newly initialized chat", function()
    Renderer.init_content(bufnr, {
      frontmatter = {
        ["vibing.nvim"] = true,
        agent = "claude",
        model = "sonnet",
      },
    })

    local content = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
    assert.is_truthy(content:find("\neffort: default\n", 1, true))
  end)

  it("shows a configured effort instead of the default sentinel", function()
    Renderer.init_content(bufnr, {
      frontmatter = {
        ["vibing.nvim"] = true,
        agent = "codex",
        model = "gpt-5.6-terra",
        effort = "high",
      },
    })

    local content = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
    assert.is_truthy(content:find("\neffort: high\n", 1, true))
  end)
end)
