---@class Vibing.Application.Chat.Search.GithubReference
---クエリが GitHub の PR / issue を指していれば、`gh` でタイトルとブランチを引く。
---
---チャットに番号が書かれていなくても、タイトルの語やブランチ名なら書かれていることが多い。
---`gh` が無い、認証していない、番号が無い、のどれでも黙って何も足さない。
local M = {}

---@class Vibing.Chat.Search.Reference
---@field context string[] キーワード展開に渡す補足
---@field terms string[] そのまま検索する語

---@param query string
---@return string? kind "pr" | "issue" | nil（どちらか分からない）
---@return string? number
function M.parse(query)
  local kind, number = query:match("/(pull)/(%d+)")
  if not number then
    kind, number = query:match("/(issues)/(%d+)")
  end
  if not number then
    number = query:match("[Pp][Rr]%s*#?(%d+)") or query:match("#(%d+)")
    kind = number and query:match("[Pp][Rr]") and "pull" or nil
  end
  if not number then
    return nil, nil
  end
  return kind == "pull" and "pr" or kind == "issues" and "issue" or nil, number
end

---@param kind string
---@param number string
---@param cwd string
---@param callback fun(info: {title: string?, headRefName: string?}?)
local function view(kind, number, cwd, callback)
  local fields = kind == "pr" and "title,headRefName" or "title"
  vim.system({ "gh", kind, "view", number, "--json", fields }, { text = true, cwd = cwd }, function(result)
    local ok, decoded = pcall(vim.json.decode, result.code == 0 and result.stdout or "")
    callback(ok and type(decoded) == "table" and decoded or nil)
  end)
end

---@param query string
---@param cwd string
---@param callback fun(reference: Vibing.Chat.Search.Reference)
function M.resolve(query, cwd, callback)
  local kind, number = M.parse(query)
  local reference = { context = {}, terms = {} }
  if not number then
    callback(reference)
    return
  end
  reference.terms = { "#" .. number, "pull/" .. number, "issues/" .. number }
  if vim.fn.executable("gh") ~= 1 then
    callback(reference)
    return
  end

  local function done(found_kind, info)
    vim.schedule(function()
      if info and info.title then
        reference.context[#reference.context + 1] = string.format("%s #%s is titled %q", found_kind, number, info.title)
      end
      if info and type(info.headRefName) == "string" and info.headRefName ~= "" then
        reference.terms[#reference.terms + 1] = info.headRefName
      end
      callback(reference)
    end)
  end

  local first = kind or "pr"
  view(first, number, cwd, function(info)
    if info or kind then
      done(first, info)
      return
    end
    view("issue", number, cwd, function(issue)
      done("issue", issue)
    end)
  end)
end

return M
