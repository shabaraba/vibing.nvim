-- `to_web_url` は純関数なので git を用意せずに全形を通せる。`M.get` のほうは
-- `git remote get-url` の薄い呼び出しで、正規化はすべてここを通る。

local RepoUrl = require("vibing.core.utils.repo_url")

describe("repo_url.to_web_url", function()
  it("normalizes the three remote shapes to the same web url", function()
    local expected = "https://github.com/org/repo"

    assert.equals(expected, RepoUrl.to_web_url("git@github.com:org/repo.git"))
    assert.equals(expected, RepoUrl.to_web_url("ssh://git@github.com/org/repo.git"))
    assert.equals(expected, RepoUrl.to_web_url("https://github.com/org/repo.git"))
    assert.equals(expected, RepoUrl.to_web_url("https://github.com/org/repo"))
  end)

  it("keeps nested paths, which self-hosted forges use", function()
    local url = RepoUrl.to_web_url("git@gitlab.example.com:group/sub/repo.git")
    assert.equals("https://gitlab.example.com/group/sub/repo", url)
  end)

  it("strips credentials so they never reach the chat file", function()
    assert.equals("https://github.com/org/repo", RepoUrl.to_web_url("https://x-access-token:secret@github.com/org/repo.git"))
    assert.equals("https://github.com/org/repo", RepoUrl.to_web_url("https://user@github.com/org/repo"))
  end)

  it("drops the port", function()
    assert.equals("https://git.example.com/org/repo", RepoUrl.to_web_url("ssh://git@git.example.com:2222/org/repo.git"))
  end)

  it("refuses remotes that are not a host", function()
    assert.is_nil(RepoUrl.to_web_url("/srv/git/repo.git"))
    assert.is_nil(RepoUrl.to_web_url("../sibling/repo"))
    assert.is_nil(RepoUrl.to_web_url("file:///srv/git/repo.git"))
    assert.is_nil(RepoUrl.to_web_url(""))
  end)

  it("strips .git even behind a trailing slash", function()
    assert.equals("https://github.com/org/repo", RepoUrl.to_web_url("https://github.com/org/repo.git/"))
  end)

  it("trims the trailing newline git leaves on its output", function()
    assert.equals("https://github.com/org/repo", RepoUrl.to_web_url("git@github.com:org/repo.git\n"))
  end)
end)
