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

  it("names the sender in the body even when the section header carries it", function()
    -- ヘッダはバッファの描画にしか無く、CLIへ渡るのはヘッダの下の本文だけ。本文が名乗らないと
    -- 受け取るモデルは配達とユーザー直接入力を区別できず、報告義務の出自条件
    -- （cli_command_builder の orchestrator 行）が判定不能になる
    local sender = make_buf("worker.md")
    local queue = { { bufnr = sender, body = "done" } }

    local text = DeliveryMessage.build(queue)

    assert.is_true(text:find("### From", 1, true) ~= nil, text)
    assert.is_true(text:find("worker.md", 1, true) ~= nil, text)
    assert.is_true(text:find("done", 1, true) ~= nil, text)
  end)

  it("keeps the From headings when several senders coalesce", function()
    local a, b, recipient = make_buf("a.md"), make_buf("b.md"), make_buf()
    direction_answers[a], direction_answers[b] = "Report", "Report"
    local queue = { { bufnr = a, body = "one" }, { bufnr = b, body = "two" } }

    local section = DeliveryMessage.section_for(queue, recipient)
    assert.equals("Report", section.kind)
    assert.is_nil(section.from, "no single sender to name")

    local text = DeliveryMessage.build(queue)
    assert.is_true(text:find("### From", 1, true) ~= nil, text)
  end)

  it("calls a watchdog-only delivery a Notice", function()
    local about, recipient = make_buf("worker.md"), make_buf()

    local section = DeliveryMessage.section_for({ { bufnr = about } }, recipient)

    assert.equals("Notice", section.kind)
    assert.is_nil(section.from)
  end)

  it("delivers a system notice as a Notice without inventing a chat sender", function()
    local recipient = make_buf()
    local queue = { { kind = "notice", body = "Background job `dev` exited." } }

    local section = DeliveryMessage.section_for(queue, recipient)
    local text = DeliveryMessage.build(queue)

    assert.equals("Notice", section.kind)
    assert.is_nil(section.from)
    assert.equals("Background job `dev` exited.", text)
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
  local original_approval_delegate
  local approval_mode

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
    approval_mode = false
    original_approval_delegate = package.loaded["vibing.application.chat.approval_delegate"]
    package.loaded["vibing.application.chat.approval_delegate"] = {
      mode = function()
        return approval_mode
      end,
    }
    package.loaded["vibing.application.chat.delivery_message"] = nil
    DeliveryMessage = require("vibing.application.chat.delivery_message")
  end)

  after_each(function()
    package.loaded["vibing.application.chat.approval_delegate"] = original_approval_delegate
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
    assert.is_falsy(text:find("rpc_port", 1, true))
  end)

  it("never asks the model to echo routing data when delegated approval is enabled", function()
    local about = make_buf("worker.md")

    for _, mode in ipairs({ true, "scoped" }) do
      approval_mode = mode
      local text = DeliveryMessage.build({ { bufnr = about, reason = "waiting_approval" } })

      assert.is_truthy(text:find("nvim_chat_answer_approval({ file_path, action,", 1, true))
      assert.is_falsy(text:find("rpc_port", 1, true))
    end
  end)

  it("explains both kinds when a blocked chat and a silent one arrive together", function()
    local blocked, silent = make_buf("blocked.md"), make_buf("silent.md")

    local text = DeliveryMessage.build({ { bufnr = blocked, reason = "asked_question" }, { bufnr = silent } })

    assert.is_truthy(text:find("status: asked_question", 1, true))
    assert.is_truthy(text:find("A chat listed without a status", 1, true))
  end)
end)

-- The report duty also lives in the worker's system prompt, but claude records that prompt on the
-- conversation's first request and replays it on every resume. A chat that gained an orchestrator
-- after its first message never sees the line naming it, so the request itself has to say where to
-- report — the per-turn body is the one thing the recording does not freeze.
describe("DeliveryMessage.deliver (report instructions)", function()
  local DeliveryMessage
  local saved, sent, direction_answers, buffers

  local function make_buf(name)
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(bufnr, vim.fn.tempname() .. "-" .. name)
    table.insert(buffers, bufnr)
    return bufnr
  end

  before_each(function()
    buffers, sent, direction_answers = {}, {}, {}
    saved = {}
    for _, name in ipairs({
      "vibing.application.chat.orchestration_link",
      "vibing.application.chat.auto_compact",
      "vibing.presentation.chat.modules.programmatic_sender",
    }) do
      saved[name] = package.loaded[name]
    end
    package.loaded["vibing.application.chat.orchestration_link"] = {
      direction = function(from_bufnr)
        return direction_answers[from_bufnr] or "Request"
      end,
    }
    package.loaded["vibing.application.chat.auto_compact"] = {
      before_delivery = function()
        return false
      end,
    }
    package.loaded["vibing.presentation.chat.modules.programmatic_sender"] = {
      send = function(bufnr, text)
        table.insert(sent, { bufnr = bufnr, text = text })
        return { success = true, bufnr = bufnr }
      end,
    }
    package.loaded["vibing.application.chat.delivery_message"] = nil
    DeliveryMessage = require("vibing.application.chat.delivery_message")
  end)

  after_each(function()
    for name, module in pairs(saved) do
      package.loaded[name] = module
    end
    package.loaded["vibing.application.chat.delivery_message"] = nil
    for _, bufnr in ipairs(buffers) do
      if vim.api.nvim_buf_is_valid(bufnr) then
        vim.api.nvim_buf_delete(bufnr, { force = true })
      end
    end
  end)

  it("tells the receiving chat where and how to report on a request", function()
    local orchestrator, worker = make_buf("orchestrator.md"), make_buf("worker.md")

    DeliveryMessage.deliver({ { bufnr = orchestrator, body = "implement it" } }, worker)

    local text = sent[1].text
    assert.is_truthy(text:find("implement it", 1, true))
    assert.is_truthy(text:find("nvim_chat_send_message", 1, true))
    assert.is_truthy(text:find("orchestrator.md", text:find("nvim_chat_send_message", 1, true), true), text)
    assert.is_truthy(text:find("from_bufnr " .. worker, 1, true), text)
    assert.is_truthy(text:find("queue_if_busy true", 1, true))
  end)

  it("names every sender once when several requests coalesce", function()
    local a, b, worker = make_buf("a.md"), make_buf("b.md"), make_buf("worker.md")

    DeliveryMessage.deliver({ { bufnr = a, body = "one" }, { bufnr = a, body = "two" }, { bufnr = b, body = "three" } }, worker)

    local text = sent[1].text
    local instructions = text:sub((text:find("Report back", 1, true)))
    local _, a_count = instructions:gsub("a%.md", "")
    assert.equals(1, a_count)
    assert.is_truthy(instructions:find("b.md", 1, true))
  end)

  it("adds nothing to a report going back to the orchestrator", function()
    local worker, orchestrator = make_buf("worker.md"), make_buf("orchestrator.md")
    direction_answers[worker] = "Report"

    DeliveryMessage.deliver({ { bufnr = worker, body = "done" } }, orchestrator)

    assert.is_nil(sent[1].text:find("nvim_chat_send_message", 1, true))
  end)

  -- An answer to a blocked question reaches the model as the human's answer, word for word, so
  -- anything appended would be read as part of that answer.
  it("adds nothing to a delivery that answers a blocked question", function()
    local orchestrator, worker = make_buf("orchestrator.md"), make_buf("worker.md")

    DeliveryMessage.deliver({ { bufnr = orchestrator, body = "option B" } }, worker, nil, {
      answers_blocked_question = true,
    })

    assert.is_nil(sent[1].text:find("Report back", 1, true))
  end)
end)
