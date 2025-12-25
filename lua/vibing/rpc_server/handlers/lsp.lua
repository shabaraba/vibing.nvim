local M = {}

-- Retrieve definition locations for the symbol at the given buffer position.
-- @param params Table with optional and required fields:
--   - bufnr: (optional) buffer number; defaults to 0.
--   - line: (required) 1-based line number of the symbol.
--   - col: (required) 0-based character offset (column) of the symbol.
-- @return A table `{ locations = locations }` where `locations` is an array of objects with `uri` and `range` keys for each definition location.
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

-- Retrieve all references for the symbol at the given buffer position.
-- @param params Table with optional and required fields.
-- @param params.bufnr (optional) Buffer number to query; defaults to 0.
-- @param params.line 1-based line number of the symbol's position.
-- @param params.col Character column of the symbol's position (0-based).
-- @return A table `{ references = references }` where `references` is an array of tables each containing `uri` and `range`; empty when no references found.
-- @throws If `line` or `col` is missing in `params`.
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

-- Retrieve hover text for the symbol at the specified buffer position.
-- @param params Table with optional field `bufnr` (buffer number, default 0) and required fields `line` (1-based line) and `col` (0-based column).
-- @throws If `line` or `col` is missing, raises an error.
-- @return Table with `contents` — a string containing the consolidated hover text (empty string when no hover information is available).
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

-- Get diagnostics for a buffer as plain tables.
-- @param params Table with optional fields:
--   - bufnr (number): Buffer number to retrieve diagnostics from. Defaults to 0.
-- @return Table with field `diagnostics`, an array of diagnostic tables. Each diagnostic contains:
--   - lnum (number)
--   - col (number)
--   - end_lnum (number)
--   - end_col (number)
--   - severity (number)
--   - message (string)
--   - source (string|nil)
--   - code (string|number|nil)
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

-- Retrieve document symbols for the given buffer.
-- @param params Table of options. Fields:
--   bufnr (number) — buffer number to query; defaults to 0.
-- @return table containing `symbols`: an array of LSP DocumentSymbol or SymbolInformation objects; empty array when no symbols are available.
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

-- Finds type definition locations for the symbol at the given buffer position.
-- @param params Table with call parameters. Fields:
--   - bufnr (number, optional): buffer number; defaults to 0.
--   - line (number): 1-based line number of the symbol.
--   - col (number): character column of the symbol (used as LSP `character`).
-- @return A table { locations = locations } where `locations` is an array of objects each containing:
--   - uri (string): document URI of the target location.
--   - range (table): LSP range table for the target location.
-- @throws Error if `line` or `col` is not provided.
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

-- Retrieves incoming call-hierarchy entries for the symbol at the specified buffer position.
-- @param params Table with fields:
--   bufnr (number|nil) — buffer number (default 0),
--   line (number) — 1-based line number of the symbol,
--   col (number) — 0-based character column of the symbol.
-- @return table `{ calls = calls }` where `calls` is an array of tables each containing:
--   `from` (call hierarchy item) and `fromRanges` (array of ranges where the call originates).
-- @throws if `line` or `col` is missing, if no LSP server is attached to the buffer, or if the prepareCallHierarchy request returns no results.
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

-- Retrieves outgoing call-hierarchy entries for the symbol at the given position.
-- @param params Table with call parameters.
-- @param params.bufnr (number|nil) Buffer number; defaults to 0.
-- @param params.line (number) 1-based line number of the symbol.
-- @param params.col (number) 0-based character column of the symbol.
-- @return table A table with a `calls` array; each entry contains `to` (call target item) and `fromRanges` (array of ranges).
-- @throws If `line` or `col` is missing.
-- @throws If no LSP server is attached to the specified buffer.
-- @throws If the prepareCallHierarchy request times out or returns no results.
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
