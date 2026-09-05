describe("DeliveryMessage.section_for", function()
  local DeliveryMessage
  local original_link
  local direction_answers
  local buffers

  ---@param name string?
  ---@return number
  local function make_buf(name)
    local bufnr = vim.api.nvim_create_buf(false, true)
    if name then
      vim.api.nvim_buf_set_name(bufnr, vim.fn.tempname() .. "-" .. name)
    end
    table.insert(buffers, bufnr)
    return bufnr
  end

  before_each(function()
    buffers = {}
    direction_answers = {}
    original_link = package.loaded["vibing.application.chat.orchestration_link"]
    package.loaded["vibing.application.chat.orchestration_link"] = {
      direction = function(from_bufnr, _)
        return direction_answers[from_bufnr] or "Request"
      end,
    }
    package.loaded["vibing.application.chat.delivery_message"] = nil
    DeliveryMessage = require("vibing.application.chat.delivery_message")
  end)

  after_each(function()
    package.loaded["vibing.application.chat.orchestration_link"] = original_link
    package.loaded["vibing.application.chat.delivery_message"] = nil
    for _, bufnr in ipairs(buffers) do
      if vim.api.nvim_buf_is_valid(bufnr) then
        vim.api.nvim_buf_delete(bufnr, { force = true })
      end
    end
  end)

  it("names the sender when one chat sent one message", function()
    local sender, recipient = make_buf("worker.md"), make_buf()
    direction_answers[sender] = "Report"

    local section = DeliveryMessage.section_for({ { bufnr = sender, body = "done" } }, recipient)

    assert.equals("Report", section.kind)
    assert.is_true(section.from:find("worker.md", 1, true) ~= nil, tostring(section.from))
  end)

  it("drops the redundant From heading once the section header carries it", function()
    local sender, recipient = make_buf("worker.md"), make_buf()
    local queue = { { bufnr = sender, body = "done" } }
    local section = DeliveryMessage.section_for(queue, recipient)

    assert.equals("done", DeliveryMessage.build(queue, section))
  end)

  it("keeps the From headings when several senders coalesce", function()
    local a, b, recipient = make_buf("a.md"), make_buf("b.md"), make_buf()
    direction_answers[a], direction_answers[b] = "Report", "Report"
    local queue = { { bufnr = a, body = "one" }, { bufnr = b, body = "two" } }

    local section = DeliveryMessage.section_for(queue, recipient)
    assert.equals("Report", section.kind)
    assert.is_nil(section.from, "no single sender to name")

    local text = DeliveryMessage.build(queue, section)
    assert.is_true(text:find("### From", 1, true) ~= nil, text)
  end)

  it("calls a watchdog-only delivery a Notice", function()
    local about, recipient = make_buf("worker.md"), make_buf()

    local section = DeliveryMessage.section_for({ { bufnr = about } }, recipient)

    assert.equals("Notice", section.kind)
    assert.is_nil(section.from)
  end)

  it("does not name a sender when a notice rides along with the message", function()
    -- 通知は別のチャットについての話なので、見出しが本文の送信元だけを名指しすると
    -- 通知が指しているチャットの出どころが消える
    local sender, about, recipient = make_buf("worker.md"), make_buf("other.md"), make_buf()
    direction_answers[sender] = "Report"

    local section = DeliveryMessage.section_for({ { bufnr = sender, body = "done" }, { bufnr = about } }, recipient)

    assert.equals("Report", section.kind)
    assert.is_nil(section.from)
  end)

  it("falls back to Report when a coalesced delivery mixes directions", function()
    local a, b, recipient = make_buf("a.md"), make_buf("b.md"), make_buf()
    direction_answers[a], direction_answers[b] = "Request", "Report"

    local section = DeliveryMessage.section_for({ { bufnr = a, body = "x" }, { bufnr = b, body = "y" } }, recipient)

    assert.equals("Report", section.kind)
  end)
end)

describe("DeliveryMessage.build (blocked chats)", function()
  local DeliveryMessage
  local buffers

  local function make_buf(name)
    local bufnr = vim.api.nvim_create_buf(false, true)
    if name then
      vim.api.nvim_buf_set_name(bufnr, vim.fn.tempname() .. "-" .. name)
    end
    table.insert(buffers, bufnr)
    return bufnr
  end

  before_each(function()
    buffers = {}
    package.loaded["vibing.application.chat.delivery_message"] = nil
    DeliveryMessage = require("vibing.application.chat.delivery_message")
  end)

  after_each(function()
    package.loaded["vibing.application.chat.delivery_message"] = nil
    for _, bufnr in ipairs(buffers) do
      if vim.api.nvim_buf_is_valid(bufnr) then
        vim.api.nvim_buf_delete(bufnr, { force = true })
      end
    end
  end)

  it("names the status so the reader can tell 'answer it' from 'only the user can'", function()
    local about = make_buf("worker.md")

    local text = DeliveryMessage.build({ { bufnr = about, reason = "waiting_approval" } })

    assert.is_truthy(text:find("status: waiting_approval", 1, true))
    assert.is_truthy(text:find("cannot continue on their own", 1, true))
    -- 状態が判っているものについて「報告せずに止まった」と言うのは推測。事実のほうを言う
    assert.is_falsy(text:find("have stopped without reporting back", 1, true))
  end)

  it("keeps the watchdog wording when no status is known", function()
    local about = make_buf("worker.md")

    local text = DeliveryMessage.build({ { bufnr = about } })

    assert.is_truthy(text:find("have stopped without reporting back", 1, true))
    assert.is_falsy(text:find("status:", 1, true))
  end)

  it("explains both kinds when a blocked chat and a silent one arrive together", function()
    local blocked, silent = make_buf("blocked.md"), make_buf("silent.md")

    local text = DeliveryMessage.build({ { bufnr = blocked, reason = "asked_question" }, { bufnr = silent } })

    assert.is_truthy(text:find("status: asked_question", 1, true))
    assert.is_truthy(text:find("A chat listed without a status", 1, true))
  end)

  it("includes the worker's tail excerpt so the reader need not fetch it separately (#693)", function()
    local about = make_buf("worker.md")

    local text = DeliveryMessage.build({
      { bufnr = about, tail = "## Assistant <!-- 2026-01-01 00:00:00 -->\nran the migration\nlooks done" },
    })

    assert.is_truthy(text:find("ran the migration", 1, true))
    assert.is_truthy(text:find("looks done", 1, true))
  end)

  it("says nothing extra when a notification carries no tail excerpt", function()
    local about = make_buf("worker.md")

    local text = DeliveryMessage.build({ { bufnr = about } })

    assert.is_falsy(text:find("last lines:", 1, true))
  end)
end)
