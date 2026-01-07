---@class Vibing.PathSanitizer
---Path traversal attack prevention module
---Normalizes and validates file paths to prevent directory traversal attacks
local M = {}

---Normalize a file path to absolute path and resolve symlinks
---@param path string File path to normalize
---@return string|nil normalized Normalized absolute path, or nil if path is invalid
---@return string|nil error Error message if normalization failed
function M.normalize(path)
  if not path or path == "" then
    return nil, "Empty path"
  end

  -- Expand ~ and environment variables
  local expanded = vim.fn.expand(path)

  -- Convert to absolute path
  local absolute = vim.fn.fnamemodify(expanded, ":p")

  -- Resolve symlinks to prevent symlink-based traversal
  local resolved = vim.fn.resolve(absolute)

  -- Check if path exists (for validation, but allow non-existent paths for write operations)
  -- We don't fail here, just normalize the path

  return resolved, nil
end

---Validate that a path is within allowed directories
---@param path string Path to validate
---@param allowed_roots string[] List of allowed root directories
---@return boolean valid True if path is within allowed roots
---@return string|nil error Error message if validation failed
function M.validate_within_roots(path, allowed_roots)
  if not path or path == "" then
    return false, "Empty path"
  end

  if not allowed_roots or #allowed_roots == 0 then
    -- If no roots specified, allow all paths (backward compatibility)
    return true, nil
  end

  -- Normalize the path first
  local normalized, err = M.normalize(path)
  if not normalized then
    return false, err
  end

  -- Check if normalized path starts with any allowed root
  for _, root in ipairs(allowed_roots) do
    local normalized_root, root_err = M.normalize(root)
    if normalized_root then
      -- Ensure root ends with separator for proper prefix matching
      if not normalized_root:match("/$") then
        normalized_root = normalized_root .. "/"
      end

      -- Check if path is within this root
      if normalized:sub(1, #normalized_root) == normalized_root then
        return true, nil
      end
    end
  end

  return false, "Path is outside allowed directories"
end

---Validate that a path doesn't contain traversal patterns
---This is a quick check before normalization
---@param path string Path to check
---@return boolean valid True if path doesn't contain obvious traversal patterns
---@return string|nil error Error message if validation failed
function M.check_traversal_patterns(path)
  if not path or path == "" then
    return false, "Empty path"
  end

  -- Check for obvious traversal patterns
  local dangerous_patterns = {
    "%.%./",     -- ../
    "/%.%./",    -- /../
    "%.%.\\",    -- ..\
    "\\%.%.\\",  -- \..\
    "^%.%.$",    -- starts with ..
    "^%.%./",    -- starts with ../
    "^%.%.\\",   -- starts with ..\
  }

  for _, pattern in ipairs(dangerous_patterns) do
    if path:match(pattern) then
      return false, "Path contains traversal pattern: " .. pattern
    end
  end

  return true, nil
end

---Sanitize a path for safe file operations
---Combines normalization and validation
---@param path string Path to sanitize
---@param allowed_roots? string[] Optional list of allowed root directories
---@return string|nil sanitized Sanitized path, or nil if validation failed
---@return string|nil error Error message if sanitization failed
function M.sanitize(path, allowed_roots)
  -- Quick pattern check first
  local pattern_ok, pattern_err = M.check_traversal_patterns(path)
  if not pattern_ok then
    return nil, pattern_err
  end

  -- Normalize the path
  local normalized, norm_err = M.normalize(path)
  if not normalized then
    return nil, norm_err
  end

  -- Validate within allowed roots if specified
  if allowed_roots and #allowed_roots > 0 then
    local valid, valid_err = M.validate_within_roots(normalized, allowed_roots)
    if not valid then
      return nil, valid_err
    end
  end

  return normalized, nil
end

return M
