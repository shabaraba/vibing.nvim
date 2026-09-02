local ConversationExtractor = require("vibing.presentation.chat.modules.conversation_extractor")

describe("ConversationExtractor.commit_user_message", function()
  local bufnr

  before_each(function()
    bufnr = vim.api.nvim_create_buf(false, true)
  end)

  after_each(function()
    if vim.api.nvim_buf_is_valid(bufnr) then
      vim.api.nvim_buf_delete(bufnr, { force = true })
    end
  end)

  ---@return string
  local function header_line()
    for _, line in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
      if line:match("^## ") then
        return line
      end
    end
    return ""
  end

  it("stamps a plain user section", function()
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "## User <!-- unsent -->", "", "hi" })

    ConversationExtractor.commit_user_message(bufnr)

    assert.is_true(header_line():match("^## User <!%-%- %d%d%d%d%-") ~= nil, header_line())
  end)

  it("keeps a delivery section's kind and sender when it stamps it", function()
    -- `## User` に決め打つと、送信の瞬間に配達セクションがただの User に化けて、
    -- 誰から届いたものかがバッファから消える
    vim.api.nvim_buf_set_lines(
      bufnr,
      0,
      -1,
      false,
      { "## Report <!-- unsent from .vibing/chat/worker.md -->", "", "done" }
    )

    ConversationExtractor.commit_user_message(bufnr)

    local line = header_line()
    assert.is_true(line:match("^## Report <!%-%- %d%d%d%d%-") ~= nil, line)
    assert.is_true(line:find("from .vibing/chat/worker.md", 1, true) ~= nil, line)
  end)

  it("extracts a delivery section's body as the message to send", function()
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "## Report <!-- unsent from x.md -->", "", "the report" })

    assert.equals("the report", ConversationExtractor.extract_user_message(bufnr))
  end)
end)
