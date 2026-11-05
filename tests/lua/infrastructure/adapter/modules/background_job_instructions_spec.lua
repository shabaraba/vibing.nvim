local BackgroundJobs = require("vibing.infrastructure.adapter.modules.background_job_instructions")

describe("background_job_instructions", function()
  it("states the criterion and the two substitutes it forbids", function()
    local text = table.concat(BackgroundJobs.lines({ tool = true }), "\n")

    assert.is_truthy(text:find(BackgroundJobs.MARKER, 1, true))
    assert.is_truthy(text:find("belongs to this turn", 1, true))
    assert.is_truthy(text:find("must still be running after this turn ends", 1, true))
    assert.is_truthy(text:find("Do not use shell backgrounding", 1, true))
    assert.is_truthy(text:find("CLI's own background-task or monitor mechanism", 1, true))
  end)

  it("names nvim_job_start only where the request can reach it", function()
    local with_tool = table.concat(BackgroundJobs.lines({ tool = true }), "\n")
    local without = table.concat(BackgroundJobs.lines({ tool = false }), "\n")

    assert.is_truthy(with_tool:find("nvim_job_start", 1, true))
    assert.is_truthy(with_tool:find("same permission rules as Bash", 1, true))
    assert.is_nil(without:find("nvim_job_start", 1, true))
    -- The criterion itself is identical, so a backend without the tool still refuses rather than
    -- registering the process in the CLI.
    assert.is_truthy(without:find("no Neovim-owned job tool", 1, true))
    assert.is_truthy(without:find(BackgroundJobs.MARKER, 1, true))
  end)

  it("prefixes a prompt without swallowing it", function()
    local prompt = BackgroundJobs.prefix("do the thing", { tool = false })

    assert.is_truthy(vim.startswith(prompt, BackgroundJobs.MARKER))
    assert.is_truthy(vim.endswith(prompt, "do the thing"))
  end)

  it("answers reachability from the bundled plugin, not from a name", function()
    local config = { integrations = { plugins = { self = false, project_dir = false } } }
    assert.is_false(BackgroundJobs.reachable(nil, config))
  end)
end)
