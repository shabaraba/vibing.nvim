local M = {}

function M.lsp_definition(params)
  local bufnr = params and params.bufnr or 0
  local line = params and params.line
  local col = params and params.col
  if not line or not col then
    error("Missing line or col parameter")
  end
  local lsp_params = {
    textDocument = vim.lsp.util.make_text_document_params(bufnr),
    position = { line = line - 1, character = col },
  }
  local result = vim.lsp.buf_request_sync(bufnr, "textDocument/definition", lsp_params, 15000)
  if not result or vim.tbl_isempty(result) then
    return { locations = {} }
  end
  local locations = {}
  for _, res in pairs(result) do
    if res.result then
      for _, loc in ipairs(res.result) do
        table.insert(locations, {
          uri = loc.uri or loc.targetUri,
          range = loc.range or loc.targetRange,
        })
      end
    end
  end
  return { locations = locations }
end

function M.lsp_references(params)
  local bufnr = params and params.bufnr or 0
  local line = params and params.line
  local col = params and params.col
  if not line or not col then
    error("Missing line or col parameter")
  end
  local lsp_params = {
    textDocument = vim.lsp.util.make_text_document_params(bufnr),
    position = { line = line - 1, character = col },
    context = { includeDeclaration = true },
  }
  local result = vim.lsp.buf_request_sync(bufnr, "textDocument/references", lsp_params, 15000)
  if not result or vim.tbl_isempty(result) then
    return { references = {} }
  end
  local references = {}
  for _, res in pairs(result) do
    if res.result then
      for _, ref in ipairs(res.result) do
        table.insert(references, {
          uri = ref.uri,
          range = ref.range,
        })
      end
    end
  end
  return { references = references }
end

function M.lsp_hover(params)
  local bufnr = params and params.bufnr or 0
  local line = params and params.line
  local col = params and params.col
  if not line or not col then
    error("Missing line or col parameter")
  end
  local lsp_params = {
    textDocument = vim.lsp.util.make_text_document_params(bufnr),
    position = { line = line - 1, character = col },
  }
  local result = vim.lsp.buf_request_sync(bufnr, "textDocument/hover", lsp_params, 15000)
  if not result or vim.tbl_isempty(result) then
    return { contents = "" }
  end
  local contents = ""
  for _, res in pairs(result) do
    if res.result and res.result.contents then
      local hover_contents = res.result.contents
      if type(hover_contents) == "string" then
        contents = hover_contents
      elseif hover_contents.value then
        contents = hover_contents.value
      elseif type(hover_contents) == "table" and #hover_contents > 0 then
        for _, item in ipairs(hover_contents) do
          if type(item) == "string" then
            contents = contents .. item .. "\n"
          elseif item.value then
            contents = contents .. item.value .. "\n"
          end
        end
      end
      break
    end
  end
  return { contents = contents }
end

function M.diagnostics_get(params)
  local bufnr = params and params.bufnr or 0
  local diagnostics = vim.diagnostic.get(bufnr)
  local result = {}
  for _, diag in ipairs(diagnostics) do
    table.insert(result, {
      lnum = diag.lnum,
      col = diag.col,
      end_lnum = diag.end_lnum,
      end_col = diag.end_col,
      severity = diag.severity,
      message = diag.message,
      source = diag.source,
      code = diag.code,
    })
  end
  return { diagnostics = result }
end

function M.lsp_document_symbols(params)
  local bufnr = params and params.bufnr or 0
  local lsp_params = { textDocument = vim.lsp.util.make_text_document_params(bufnr) }
  local result = vim.lsp.buf_request_sync(bufnr, "textDocument/documentSymbol", lsp_params, 15000)
  if not result or vim.tbl_isempty(result) then
    return { symbols = {} }
  end
  local symbols = {}
  for _, res in pairs(result) do
    if res.result then
      symbols = res.result
      break
    end
  end
  return { symbols = symbols }
end

function M.lsp_type_definition(params)
  local bufnr = params and params.bufnr or 0
  local line = params and params.line
  local col = params and params.col
  if not line or not col then
    error("Missing line or col parameter")
  end
  local lsp_params = {
    textDocument = vim.lsp.util.make_text_document_params(bufnr),
    position = { line = line - 1, character = col },
  }
  local result = vim.lsp.buf_request_sync(bufnr, "textDocument/typeDefinition", lsp_params, 15000)
  if not result or vim.tbl_isempty(result) then
    return { locations = {} }
  end
  local locations = {}
  for _, res in pairs(result) do
    if res.result then
      for _, loc in ipairs(res.result) do
        table.insert(locations, {
          uri = loc.uri or loc.targetUri,
          range = loc.range or loc.targetRange,
        })
      end
    end
  end
  return { locations = locations }
end

function M.lsp_call_hierarchy_incoming(params)
  local bufnr = params and params.bufnr or 0
  local line = params and params.line
  local col = params and params.col
  if not line or not col then
    error("Missing line or col parameter")
  end

  -- Check if LSP is attached (compatible with Neovim 0.8+)
  local clients
  if vim.lsp.get_clients then
    -- Neovim 0.10+
    clients = vim.lsp.get_clients({ bufnr = bufnr })
  else
    -- Neovim 0.8-0.9
    clients = vim.lsp.buf_get_clients(bufnr)
  end
  if not clients or #clients == 0 then
    error(string.format("No LSP server attached to buffer %d. Make sure the file is loaded and LSP is initialized.", bufnr))
  end

  local lsp_params = {
    textDocument = vim.lsp.util.make_text_document_params(bufnr),
    position = { line = line - 1, character = col },
  }
  local result = vim.lsp.buf_request_sync(bufnr, "textDocument/prepareCallHierarchy", lsp_params, 15000)
  if not result or vim.tbl_isempty(result) then
    error("LSP request timed out or returned no results. The LSP server may be busy or the symbol may not support call hierarchy.")
  end
  local items = {}
  for _, res in pairs(result) do
    if res.result and #res.result > 0 then
      items = res.result
      break
    end
  end
  if #items == 0 then
    return { calls = {} }
  end
  local incoming_params = { item = items[1] }
  local incoming_result = vim.lsp.buf_request_sync(bufnr, "callHierarchy/incomingCalls", incoming_params, 15000)
  if not incoming_result or vim.tbl_isempty(incoming_result) then
    return { calls = {} }
  end
  local calls = {}
  for _, res in pairs(incoming_result) do
    if res.result then
      for _, call in ipairs(res.result) do
        table.insert(calls, {
          from = call.from,
          fromRanges = call.fromRanges,
        })
      end
    end
  end
  return { calls = calls }
end

function M.lsp_call_hierarchy_outgoing(params)
  local bufnr = params and params.bufnr or 0
  local line = params and params.line
  local col = params and params.col
  if not line or not col then
    error("Missing line or col parameter")
  end

  -- Check if LSP is attached (compatible with Neovim 0.8+)
  local clients
  if vim.lsp.get_clients then
    -- Neovim 0.10+
    clients = vim.lsp.get_clients({ bufnr = bufnr })
  else
    -- Neovim 0.8-0.9
    clients = vim.lsp.buf_get_clients(bufnr)
  end
  if not clients or #clients == 0 then
    error(string.format("No LSP server attached to buffer %d. Make sure the file is loaded and LSP is initialized.", bufnr))
  end

  local lsp_params = {
    textDocument = vim.lsp.util.make_text_document_params(bufnr),
    position = { line = line - 1, character = col },
  }
  local result = vim.lsp.buf_request_sync(bufnr, "textDocument/prepareCallHierarchy", lsp_params, 15000)
  if not result or vim.tbl_isempty(result) then
    error("LSP request timed out or returned no results. The LSP server may be busy or the symbol may not support call hierarchy.")
  end
  local items = {}
  for _, res in pairs(result) do
    if res.result and #res.result > 0 then
      items = res.result
      break
    end
  end
  if #items == 0 then
    return { calls = {} }
  end
  local outgoing_params = { item = items[1] }
  local outgoing_result = vim.lsp.buf_request_sync(bufnr, "callHierarchy/outgoingCalls", outgoing_params, 15000)
  if not outgoing_result or vim.tbl_isempty(outgoing_result) then
    return { calls = {} }
  end
  local calls = {}
  for _, res in pairs(outgoing_result) do
    if res.result then
      for _, call in ipairs(res.result) do
        table.insert(calls, {
          to = call.to,
          fromRanges = call.fromRanges,
        })
      end
    end
  end
  return { calls = calls }
end

return M
