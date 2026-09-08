--- Project-local Codex permission profiles (`.vibing/codex-permissions.toml`).
---
--- Codex only discovers project config from `.codex/config.toml`, and `codex exec` has no flag
--- for an arbitrary config file. vibing.nvim keeps its local, git-ignored state under `.vibing/`,
--- so this module reads the permission-only file there and turns it into byte-stable `-c`
--- overrides for each ordinary Codex invocation.
---
--- The file uses the same table form as Codex config.toml. We parse only single-line scalar
--- assignments because the permission schema contains strings, booleans and one integer; the
--- nested tables are rendered into one inline TOML table. That last step is important: Codex's
--- `-c` key path does not understand quoted segments such as `":workspace_roots"`, whereas an
--- inline TOML value does.
--- @module vibing.infrastructure.adapter.modules.codex_permission_profile

local Toml = require("vibing.core.utils.toml")

local M = {}

local MAX_BYTES = 64 * 1024
local git_common_dir_cache = {}

--- Memo of the last compiled result per resolved path and request cwd, so unchanged content is not
--- re-parsed by the hand-rolled TOML parser and does not re-spawn `git rev-parse` on every ordinary
--- turn
--- (`M.args` runs on every one, new session and resume alike). The file is still read every call
--- -- keyed on file *content*, not mtime/size: mtime has only second resolution, and two edits
--- within the same second that happen to leave the byte count unchanged (`"write"` -> `"deny"`)
--- would otherwise collide, silently serving stale args and breaking the promise in
--- handbook/configuration.md that an edit takes effect on the very next turn.
--- @type table<string, {lines: string[], args: string[]}>
local file_cache = {}

local function trim(value)
  return vim.trim(value or "")
end

local function parse_error(path, line_number, message)
  error(string.format("%s:%d: %s", path, line_number, message), 0)
end

--- Find the first occurrence of `target` in `line` that is outside any quoted TOML string,
--- tracking double-quote escapes (`\"`) and treating single-quoted strings as fully literal.
--- Shared by `strip_comment` (target `#`) and `assignment_equals` (target `=`), which otherwise
--- differed only in what they did with the index once found.
--- @param line string
--- @param target string single character to look for
--- @return number|nil
local function find_unquoted_char(line, target)
  local quote = nil
  local escaped = false

  for i = 1, #line do
    local char = line:sub(i, i)
    if quote == '"' then
      if escaped then
        escaped = false
      elseif char == "\\" then
        escaped = true
      elseif char == quote then
        quote = nil
      end
    elseif quote == "'" then
      if char == quote then
        quote = nil
      end
    elseif char == '"' or char == "'" then
      quote = char
    elseif char == target then
      return i
    end
  end

  return nil
end

--- Remove a TOML comment while leaving `#` characters inside quoted values alone.
--- @param line string
--- @return string
local function strip_comment(line)
  local index = find_unquoted_char(line, "#")
  return index and line:sub(1, index - 1) or line
end

--- Decode one quoted TOML key. Permission paths and domains do not need TOML's multiline or
--- line-continuation forms, so rejecting those is clearer than silently changing their meaning.
--- @param raw string
--- @param path string
--- @param line_number number
--- @return string
local function decode_quoted_key(raw, path, line_number)
  if raw:sub(1, 1) == "'" then
    return raw:sub(2, -2)
  end

  local ok, decoded = pcall(vim.json.decode, raw)
  if not ok or type(decoded) ~= "string" then
    parse_error(path, line_number, "unsupported escape in quoted key")
  end
  return decoded
end

--- Parse a TOML dotted key, preserving dots inside quoted segments.
--- @param source string
--- @param path string
--- @param line_number number
--- @return string[]
local function parse_key(source, path, line_number)
  local parts = {}
  local index = 1
  local length = #source

  local function skip_space()
    while index <= length and source:sub(index, index):match("%s") do
      index = index + 1
    end
  end

  while true do
    skip_space()
    if index > length then
      parse_error(path, line_number, "empty TOML key segment")
    end

    local char = source:sub(index, index)
    local segment
    if char == '"' or char == "'" then
      local quote = char
      local start = index
      local escaped = false
      index = index + 1
      while index <= length do
        char = source:sub(index, index)
        if quote == '"' and escaped then
          escaped = false
        elseif quote == '"' and char == "\\" then
          escaped = true
        elseif char == quote then
          break
        end
        index = index + 1
      end
      if index > length then
        parse_error(path, line_number, "unterminated quoted TOML key")
      end
      segment = decode_quoted_key(source:sub(start, index), path, line_number)
      index = index + 1
    else
      local start = index
      while index <= length and source:sub(index, index):match("[%w_%-]") do
        index = index + 1
      end
      segment = source:sub(start, index - 1)
      if segment == "" then
        parse_error(path, line_number, "invalid bare TOML key")
      end
    end

    table.insert(parts, segment)
    skip_space()
    if index > length then
      break
    end
    if source:sub(index, index) ~= "." then
      parse_error(path, line_number, "expected '.' between TOML key segments")
    end
    index = index + 1
  end

  return parts
end

--- @param line string
--- @return number|nil
local function assignment_equals(line)
  return find_unquoted_char(line, "=")
end

local function table_node()
  return { kind = "table", children = {} }
end

local function value_node(raw)
  return { kind = "value", raw = raw }
end

--- @param root table
--- @param parts string[]
--- @param path string
--- @param line_number number
--- @return table
local function ensure_table(root, parts, path, line_number)
  local current = root
  for _, part in ipairs(parts) do
    local child = current.children[part]
    if not child then
      child = table_node()
      current.children[part] = child
    elseif child.kind ~= "table" then
      parse_error(path, line_number, string.format("%q is already a value", part))
    end
    current = child
  end
  return current
end

--- @param root table
--- @param parts string[]
--- @param raw string
--- @param path string
--- @param line_number number
local function put_value(root, parts, raw, path, line_number)
  local parent_parts = {}
  for i = 1, #parts - 1 do
    table.insert(parent_parts, parts[i])
  end
  local parent = ensure_table(root, parent_parts, path, line_number)
  local key = parts[#parts]
  if parent.children[key] then
    parse_error(path, line_number, string.format("duplicate value for %q", table.concat(parts, ".")))
  end
  parent.children[key] = value_node(raw)
end

--- @param lines string[]
--- @param path string
--- @return table
local function parse(lines, path)
  local root = table_node()
  local section = {}
  local has_content = false

  for line_number, original in ipairs(lines) do
    local line = original
    if line_number == 1 then
      line = line:gsub("^\239\187\191", "")
    end
    line = trim(strip_comment(line))
    if line ~= "" then
      has_content = true
      if line:sub(1, 1) == "[" then
        if line:sub(1, 2) == "[[" or line:sub(-1) ~= "]" then
          parse_error(path, line_number, "only ordinary TOML table headers are supported")
        end
        section = parse_key(trim(line:sub(2, -2)), path, line_number)
        ensure_table(root, section, path, line_number)
      else
        local equals = assignment_equals(line)
        if not equals then
          parse_error(path, line_number, "expected a single-line key = value assignment")
        end
        local key = parse_key(trim(line:sub(1, equals - 1)), path, line_number)
        local raw = trim(line:sub(equals + 1))
        if raw == "" then
          parse_error(path, line_number, "missing TOML value")
        end
        local full_key = vim.list_extend(vim.deepcopy(section), key)
        put_value(root, full_key, raw, path, line_number)
      end
    end
  end

  return root, has_content
end

--- @param raw string
--- @param path string
--- @return string
local function decode_profile_name(raw, path)
  if raw:sub(1, 1) == "'" and raw:sub(-1) == "'" then
    return raw:sub(2, -2)
  end
  local ok, decoded = pcall(vim.json.decode, raw)
  if not ok or type(decoded) ~= "string" then
    error(path .. ": default_permissions must be a quoted string", 0)
  end
  return decoded
end

--- @param raw string
--- @return string|nil
local function decode_string(raw)
  if raw:sub(1, 1) == "'" and raw:sub(-1) == "'" then
    return raw:sub(2, -2)
  end
  local ok, decoded = pcall(vim.json.decode, raw)
  return ok and type(decoded) == "string" and decoded or nil
end

--- @param node table|nil
--- @param key string
--- @return table|nil
local function table_child(node, key)
  if not node or node.kind ~= "table" then
    return nil
  end
  local child = node.children[key]
  return child and child.kind == "table" and child or nil
end

--- @param profiles table
--- @param name string
--- @param seen table<string, boolean>?
--- @return boolean
local function grants_git_write(profiles, name, seen)
  seen = seen or {}
  if seen[name] then
    return false
  end
  seen[name] = true

  local profile = profiles.children[name]
  if not profile or profile.kind ~= "table" then
    return false
  end
  local workspace_rules = table_child(table_child(profile, "filesystem"), ":workspace_roots")
  local git_rule = workspace_rules and workspace_rules.children[".git"]
  if git_rule and git_rule.kind == "value" and decode_string(git_rule.raw) == "write" then
    return true
  end

  local extends = profile.children.extends
  local parent = extends and extends.kind == "value" and decode_string(extends.raw) or nil
  return parent ~= nil and parent:sub(1, 1) ~= ":" and grants_git_write(profiles, parent, seen)
end

--- `filesystem.":workspace_roots".".git" = "write"` points at `<cwd>/.git`. In a linked
--- worktree that is only the gitfile; the mutable index, refs and objects live in the repository's
--- common git directory outside the worktree root. Resolve that directory and grant the same
--- write access there, so the rule means "Git metadata" in both ordinary and linked worktrees.
--- @param cwd string|nil
--- @return string|nil
local function git_common_dir(cwd)
  if not cwd or cwd == "" then
    return nil
  end
  if git_common_dir_cache[cwd] ~= nil then
    return git_common_dir_cache[cwd] or nil
  end

  local commands = {
    { "git", "rev-parse", "--path-format=absolute", "--git-common-dir" },
    -- Git before 2.31 has no --path-format. Its output may be relative, which is normalized below.
    { "git", "rev-parse", "--git-common-dir" },
  }
  local result
  for _, command in ipairs(commands) do
    local ok_system, process = pcall(vim.system, command, { cwd = cwd, text = true })
    if ok_system then
      local ok_wait, candidate = pcall(function()
        return process:wait()
      end)
      if
        ok_wait
        and type(candidate) == "table"
        and candidate.code == 0
        and trim(candidate.stdout) ~= ""
      then
        result = candidate
        break
      end
    end
  end
  if not result then
    git_common_dir_cache[cwd] = false
    return nil
  end

  local resolved = trim(result.stdout)
  if resolved == "" then
    git_common_dir_cache[cwd] = false
    return nil
  end
  if resolved:sub(1, 1) ~= "/" and not resolved:match("^%a:[/\\]") then
    resolved = cwd:gsub("/+$", "") .. "/" .. resolved
  end
  resolved = vim.fs.normalize(resolved):gsub("/+$", "")
  git_common_dir_cache[cwd] = resolved
  return resolved
end

--- @param profiles table|nil
--- @param profile_name string
--- @param cwd string|nil
local function materialize_worktree_git_access(profiles, profile_name, cwd)
  if not profiles or profiles.kind ~= "table" or not grants_git_write(profiles, profile_name) then
    return
  end
  local common_dir = git_common_dir(cwd)
  if not common_dir then
    return
  end
  local local_git = vim.fs.normalize(cwd:gsub("/+$", "") .. "/.git"):gsub("/+$", "")
  if common_dir == local_git then
    return
  end

  local selected = profiles.children[profile_name]
  local filesystem = ensure_table(selected, { "filesystem" }, "<generated>", 0)
  if not filesystem.children[common_dir] then
    filesystem.children[common_dir] = value_node(Toml.string("write"))
  end
end

--- @param key string
--- @return string
local function render_key(key)
  return Toml.is_bare_key(key) and key or Toml.string(key)
end

--- @param node table
--- @return string
local function render_table(node)
  local keys = vim.tbl_keys(node.children)
  table.sort(keys)
  local fields = {}
  for _, key in ipairs(keys) do
    local child = node.children[key]
    local value = child.kind == "table" and render_table(child) or child.raw
    table.insert(fields, string.format("%s = %s", render_key(key), value))
  end
  return "{ " .. table.concat(fields, ", ") .. " }"
end

local function append_override(args, key, value)
  table.insert(args, "-c")
  table.insert(args, key .. "=" .. value)
end

--- @param root table
--- @param path string
--- @param cwd string|nil
--- @return string[]
local function compile(root, path, cwd)
  for key in pairs(root.children) do
    if key ~= "default_permissions" and key ~= "permissions" and key ~= "features" then
      error(string.format("%s: unsupported top-level key %q", path, key), 0)
    end
  end

  local selected = root.children.default_permissions
  if not selected or selected.kind ~= "value" then
    error(path .. ": default_permissions is required", 0)
  end
  local profile_name = decode_profile_name(selected.raw, path)
  if profile_name == ":danger-full-access" then
    error(
      path
        .. ": :danger-full-access is not allowed in a project file; use permission_mode=bypassPermissions explicitly",
      0
    )
  end

  local permissions = root.children.permissions
  if profile_name:sub(1, 1) ~= ":" then
    if not permissions or permissions.kind ~= "table" or not permissions.children[profile_name] then
      error(string.format("%s: selected profile %q is not defined", path, profile_name), 0)
    end
    if permissions.children[profile_name].kind ~= "table" then
      error(string.format("%s: selected profile %q must be a table", path, profile_name), 0)
    end
  end

  if profile_name:sub(1, 1) ~= ":" then
    materialize_worktree_git_access(permissions, profile_name, cwd)
  end

  local features = root.children.features
  if features then
    if features.kind ~= "table" then
      error(path .. ": features must be a table", 0)
    end
    for key in pairs(features.children) do
      if key ~= "network_proxy" then
        error(string.format("%s: only features.network_proxy is allowed", path), 0)
      end
    end
  end

  local args = {}
  append_override(args, "default_permissions", selected.raw)
  if permissions then
    if permissions.kind ~= "table" then
      error(path .. ": permissions must be a table", 0)
    end
    append_override(args, "permissions", render_table(permissions))
  end
  if features and features.children.network_proxy then
    local network_proxy = features.children.network_proxy
    if network_proxy.kind ~= "value" then
      error(path .. ": features.network_proxy must be a value", 0)
    end
    append_override(args, "features.network_proxy", network_proxy.raw)
  end
  return args
end

--- @param base string
--- @param relative string
--- @return string
local function join(base, relative)
  return base:gsub("/+$", "") .. "/" .. relative:gsub("^/+", "")
end

--- Locate the project file. A worktree-local file wins; because `.vibing/` is normally ignored
--- and absent from worktrees, fall back to the root Neovim was started in when it belongs to the
--- same Git repository.
---
--- Returns the effective command cwd alongside the path. It may differ from the directory holding
--- the file when a worktree inherits the Neovim root's profile, and must remain the worktree so
--- `.git` write access is remapped to its shared Git directory. A nil/empty cwd is replaced by the
--- Neovim root.
--- @param cwd string|nil
--- @param configured_path string
--- @return string|nil path
--- @return string|nil effective_cwd
local function resolve_path(cwd, configured_path)
  local nvim_root = vim.fn.getcwd(-1, -1)
  local effective = cwd and cwd ~= "" and cwd or nvim_root
  if configured_path:sub(1, 1) == "/" or configured_path:match("^~") then
    local absolute = vim.fn.expand(configured_path)
    if vim.fn.filereadable(absolute) == 1 then
      return absolute, effective
    end
    return nil, effective
  end

  local local_path = join(effective, configured_path)
  if vim.fn.filereadable(local_path) == 1 then
    return local_path, effective
  end
  if effective ~= nvim_root then
    local root_path = join(nvim_root, configured_path)
    -- A chat may deliberately point at an unrelated project. Only inherit the Neovim root's
    -- ignored `.vibing/` file when both directories belong to the same Git repository.
    if
      vim.fn.filereadable(root_path) == 1
      and git_common_dir(effective) ~= nil
      and git_common_dir(effective) == git_common_dir(nvim_root)
    then
      return root_path, effective
    end
  end
  return nil, effective
end

--- Build the `-c` argv fragment for one request.
--- @param cwd string|nil effective chat working directory
--- @param config Vibing.Config
--- @return string[]
function M.args(cwd, config)
  local configured_path = config.permissions and config.permissions.codex_profile_file
  if type(configured_path) ~= "string" or configured_path == "" then
    return {}
  end

  local path, effective_cwd = resolve_path(cwd, configured_path)
  if not path then
    return {}
  end
  local size = vim.fn.getfsize(path)
  if size > MAX_BYTES then
    error(string.format("%s exceeds the %d-byte limit", path, MAX_BYTES), 0)
  end

  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok or type(lines) ~= "table" then
    error(path .. ": could not read Codex permission profile", 0)
  end

  -- Compilation may add a cwd-specific absolute Git common-directory rule. A path-only cache
  -- would let whichever worktree called first leak its rendered permissions into every other cwd.
  local cache_key = path .. "\0" .. effective_cwd
  local cached = file_cache[cache_key]
  if cached and vim.deep_equal(cached.lines, lines) then
    return vim.deepcopy(cached.args)
  end

  local root, has_content = parse(lines, path)
  if not has_content then
    file_cache[cache_key] = { lines = lines, args = {} }
    return {}
  end
  -- effective_cwd, not the raw `cwd` argument: a chat with no `working_dir` frontmatter passes
  -- `cwd == nil` here, and resolve_path already substituted the real directory the file was
  -- found in. Passing `cwd` through unchanged would make the `.git` worktree remap below silently
  -- no-op for exactly that (common) case.
  local args = compile(root, path, effective_cwd)
  file_cache[cache_key] = { lines = lines, args = args }
  return vim.deepcopy(args)
end

--- Forget git common-directory lookups and cached compiled profiles. Test seam, and useful after
--- replacing a worktree in place: `file_cache` invalidates itself on any content change, but a
--- worktree recreated at the same path with byte-identical profile content would still leave a
--- stale `git_common_dir_cache` entry that nothing else would refresh before a restart.
function M.clear_cache()
  git_common_dir_cache = {}
  file_cache = {}
end

return M
