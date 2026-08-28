---@class Vibing.Core.Utils.RepoUrl
---`origin` の remote URL を、チャットファイルに書けるブラウザで開ける URL へ正規化する。
---
---`git.lua` ではなくここに置いているのは、これが git 操作ではなく URL の正規化だからで、
---正規化のほうは git を叩かずに単体で試せる（`to_web_url` が純関数なのはそのため）。
local M = {}

---remote URL を `https://<host>/<path>` に正規化する
---
---scp 風（`git@host:org/repo.git`）、`ssh://`、`https://` のいずれも同じ形にする。
---userinfo は必ず落とす: 認証情報を URL に埋めた remote
---（`https://x-access-token:<token>@github.com/org/repo`）をそのまま要約に書くと、
---チャットファイルに資格情報が残り、そのまま git に入る。
---@param remote string
---@return string|nil web_url ホスト名として読めない remote（ローカルパス等）は nil
function M.to_web_url(remote)
  -- 末尾スラッシュを先に落とす。`https://host/org/repo.git/` は実在する書き方で、
  -- 逆順だと `.git$` が当たらず `.git` が残ったままの URL を返す
  local url = vim.trim(remote or ""):gsub("/+$", ""):gsub("%.git$", "")
  if url == "" then
    return nil
  end

  local host, path = url:match("^[^/@]+@([^/:]+):(.+)$")

  if not host then
    local rest = url:match("^%a[%w+.%-]*://(.+)$")
    if not rest then
      return nil
    end
    -- userinfo を落とす。`[^/]*` はパス区切りを越えないので、パス中の `@` には当たらない
    rest = rest:gsub("^[^/]*@", "")
    local authority
    authority, path = rest:match("^([^/]+)/(.+)$")
    if not authority then
      return nil
    end
    host = authority:gsub(":%d+$", "")
  end

  -- ローカルパスを remote にしている場合にでっち上げの https URL を返さないための下限
  if not host:find("%.") then
    return nil
  end

  -- ホスト名だけ小文字に畳む。`git@GitHub.com:...` は有効な remote だが、そのまま返すと
  -- 呼び出し側のホスト判定（`use_case` の github.com 判定）が外れてリンクが出なくなる。
  -- パスは畳まない: GitHub も GitLab も org/repo 名の大文字小文字を保持する
  return "https://" .. host:lower() .. "/" .. path
end

---`origin` の URL を取得して正規化する
---@param cwd string|nil 基準ディレクトリ（nil なら Neovim 自身のカレントディレクトリ）
---@return string|nil web_url origin が無い / Git 管理外 / 正規化できない場合は nil
function M.get(cwd)
  local opts = { text = true }
  if cwd then
    opts.cwd = cwd
  end

  local ok, result = pcall(function()
    return vim.system({ "git", "remote", "get-url", "origin" }, opts):wait()
  end)
  if not ok or result.code ~= 0 then
    return nil
  end

  return M.to_web_url(result.stdout or "")
end

return M
