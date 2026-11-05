-- `agent:` を変えたら `model:` がそのバックエンドの既定へ追従すること。
--
-- frontmatter は利用者が直接編集する前提なので、監視はバッファの TextChanged / InsertLeave に
-- 置いてある。ここでは追従の判断（`sync`）と、バッファ編集から実際に走る配線の両方を押さえる。

local handler = require("vibing.presentation.chat.modules.frontmatter_handler")
local sync = require("vibing.presentation.chat.modules.agent_model_sync")

describe("agent_model_sync", function()
  local buf

  ---@param lines string[]
  local function open(lines)
    buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    return buf
  end

  local function model()
    return handler.parse(buf).model
  end

  before_each(function()
    require("vibing").setup({
      ai = {
        chat = { agent = "claude" },
        agents = { codex = { chat_model = "gpt-6-sol" } },
      },
    })
  end)

  after_each(function()
    if buf and vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_delete(buf, { force = true })
    end
    require("vibing.config").setup({})
  end)

  it("rewrites model to the selected backend's default", function()
    open({ "---", "agent: claude", "model: sonnet", "---", "" })
    sync.watch(buf)

    handler.update_field(buf, "agent", "codex", false)
    sync.sync(buf)

    assert.equals("gpt-6-sol", model())
  end)

  it("does not touch a model that was chosen for the current agent", function()
    open({ "---", "agent: codex", "model: gpt-6-luna", "---", "" })
    sync.watch(buf)

    sync.sync(buf)

    assert.equals("gpt-6-luna", model())
  end)

  it("drops the model when the backend has no default of its own", function()
    open({ "---", "agent: claude", "model: sonnet", "---", "" })
    sync.watch(buf)

    handler.update_field(buf, "agent", "copilot", false)
    sync.sync(buf)

    assert.is_nil(model())
  end)

  it("leaves model alone for an unknown agent", function()
    open({ "---", "agent: claude", "model: sonnet", "---", "" })
    sync.watch(buf)

    handler.update_field(buf, "agent", "not-a-backend", false)
    sync.sync(buf)

    assert.equals("sonnet", model())
  end)

  it("follows an agent edit made in a chat buffer", function()
    open({ "---", "vibing.nvim: true", "agent: claude", "model: sonnet", "---", "", "# Vibing Chat" })
    vim.api.nvim_set_current_buf(buf)
    require("vibing.presentation.chat.view")._apply_chat_buffer_settings(buf)

    handler.update_field(buf, "agent", "codex", false)
    vim.cmd("doautocmd <nomodeline> TextChanged")
    vim.wait(500, function()
      return handler.parse(buf).model == "gpt-6-sol"
    end)

    assert.equals("gpt-6-sol", handler.parse(buf).model)
  end)
end)
