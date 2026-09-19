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

--- The question side of "what is a prompt line" (#788).
---
--- Approvals can be recognised from the text — a fixed header, a `<!-- vibing:req=... -->` marker —
--- and `approval_parser.strip_prompt_lines` owns that judgement. A question's block has neither: it
--- is a line of prose and `1. Label`, which is also what a person writes. So the stripper does not
--- judge at all; it rebuilds what the writer would have written and removes that exact run.
describe("renderer.strip_choice_lines", function()
  local Renderer = require("vibing.presentation.chat.modules.renderer")

  local CHOICES = { { question = "Which approach?", options = { { label = "A" }, { label = "B" } } } }

  it("removes the block it would have written, and nothing else", function()
    local drawn = Renderer.choice_lines(CHOICES)
    local lines = vim.list_extend({ "before" }, vim.deepcopy(drawn))
    table.insert(lines, "A, but keep the old names")

    assert.same({ "before", "A, but keep the old names" }, Renderer.strip_choice_lines(lines, CHOICES))
  end)

  it("leaves an edited block alone, because an edit is the answer", function()
    -- Deleting the option you do not want is how a person answers a multiple-choice prompt. What
    -- is left is no longer what the renderer wrote, and carrying it over is the whole point.
    local lines = { "Which approach?", "", "1. A", "" }

    assert.same(lines, Renderer.strip_choice_lines(lines, CHOICES))
  end)

  it("does nothing when no choices are drawn", function()
    local lines = { "1. A", "" }

    assert.same(lines, Renderer.strip_choice_lines(lines, nil))
  end)

  it("removes only the first copy when the same block appears twice", function()
    local drawn = Renderer.choice_lines(CHOICES)
    local lines = vim.list_extend(vim.deepcopy(drawn), vim.deepcopy(drawn))

    assert.same(drawn, Renderer.strip_choice_lines(lines, CHOICES))
  end)
end)
