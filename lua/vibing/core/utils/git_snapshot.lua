---@class Vibing.Utils.GitSnapshot
---リクエスト単位のツリースナップショット差分
---
---`request_diff.lua` はPreToolUseフックで **ツールの引数に現れたファイル** だけを退避するため、
---Bash（`sed -i`、`npm run format`、`mv`…）による変更を1つも捕捉できない。ここではワーキング
---ツリー全体をgitのツリーオブジェクトとしてスナップショットし、リクエスト前後の2つのツリーを
---`git diff` にかけることで、**誰がどう変更したかに関係なく** 変更を拾う。
---
---ユーザーのindex（ステージング状態）とワーキングツリーには一切干渉しない。`git add -A` は
---`GIT_INDEX_FILE` で一時indexに向けて実行するので、`.git/index.lock` を取ることもない。
---
---コストの支配項は `git add -A` のファイルスキャンで、1万ファイル規模で10〜30ms程度。
---ベースラインは「最初の変更しうるツール」のPreToolUseまで遅延させるので、読み取りだけの
---ターンではgitプロセスが1つも起動しない。
local M = {}

local Tools = require("vibing.core.constants.tools")

---ref名の親。`refs/worktree/` はgitがper-worktreeとして扱う名前空間（git 2.23以降）なので、
---worktreeを消せばそこに残ったrefも一緒に消える＝共有ref storeにゴミが残らない。
local REF_PREFIX = "refs/worktree/vibing/"

---clearされなかったセッション（キャンセル・クラッシュ）の掃除用TTL（秒）
local SESSION_TTL_SEC = 3600

---vibing.nvim自身の状態ディレクトリ。チャットファイル・patch・worktreeがここに入り、
---ターン中にも書き換わる。`.gitignore` に入れている人の場合は `git add -A` が既に無視するが、
---入れていない人では毎ターンの `### Modified Files` に会話ログ自身が並び、patchに全文が入って
---しまう。削除したmote統合が `.moteignore` で同じものを外していたのと同じ理由で、ここでも
---pathspecで外す（`git add` で外すのはハッシュ計算の節約、`git diff` で外すのが本命）。
---@type string
local EXCLUDE_VIBING_DIR = ":(exclude).vibing"

---commit-treeはcommitterのidentityを要求する。ユーザーが `user.email` を設定していない環境
---（CI・素のコンテナ）でスナップショットだけ失敗するのを避けるため、この呼び出しにだけ効く
---identityを渡す。ユーザーのgit設定は読みも書きもしない。
local GIT_ENV = {
  GIT_AUTHOR_NAME = "vibing.nvim",
  GIT_AUTHOR_EMAIL = "vibing@localhost",
  GIT_COMMITTER_NAME = "vibing.nvim",
  GIT_COMMITTER_EMAIL = "vibing@localhost",
}

---`INTERNAL_TOOLS` は「ハーネスの制御に必須なので常に許可する」一覧であって読み取り専用一覧では
---ない。NotebookEdit / Agent / Task / EnterWorktree はファイルに手が届くので、除外リストから
---外して「変更しうる側」に戻す。
---@type table<string, boolean>
local INTERNAL_TOOLS_THAT_MUTATE = {
  NotebookEdit = true,
  Agent = true,
  Task = true,
  EnterWorktree = true,
  ExitWorktree = true,
}

---ベースラインを取らなくてよいツール（＝ファイルを変更しえないと分かっているもの）。
---
---「変更しうるツールの一覧」ではなく **除外リスト** なのは安全側に倒すため。MCPツールのように
---名前から性質が分からないものは変更しうる側として扱われ、余分なスナップショットを1回取るだけで
---済む。逆に許可リスト方式だと、知らないツール名の変更を丸ごと取りこぼす。
---@type table<string, boolean>
local NON_MUTATING_TOOLS = {
  Read = true,
  Glob = true,
  Grep = true,
  WebFetch = true,
  WebSearch = true,
}
for _, name in ipairs(Tools.INTERNAL_TOOLS or {}) do
  if not INTERNAL_TOOLS_THAT_MUTATE[name] then
    NON_MUTATING_TOOLS[name] = true
  end
end

---@class Vibing.GitSnapshot.Session
---@field root string worktreeルート（絶対パス）
---@field base string ベースラインのcommit SHA
---@field ref string|nil 作成できたrefの完全名（作成できなかった場合nil）
---@field created number セッション作成時刻（os.time）
---@field overlapped boolean 自分の書き込みウィンドウ中に、同じworktreeで別のリクエストの
---  ウィンドウが開いていたか（差分の帰属ができないので、記録した側は両方フォールバックする）

---@type table<string, Vibing.GitSnapshot.Session>
local sessions = {}

---cwd → worktreeルートのキャッシュ。成功した解決だけを覚える（失敗を覚えると、あとから
---作られたworktreeが永久に「gitではない」ままになる）
---@type table<string, string>
local root_cache = {}

---残留ref掃除を済ませたworktreeルート（Neovimセッション内で1 rootにつき1回）
---@type table<string, boolean>
local swept_roots = {}

---@param cmd string[]
---@param root string
---@return vim.SystemCompleted|nil
local function git(cmd, root, env)
  local ok, result = pcall(function()
    return vim.system(cmd, { cwd = root, text = true, env = env }):wait()
  end)
  if not ok then
    return nil
  end
  return result
end

---worktreeルートを解決する
---
---`get_cwd()` はworktree内のサブディレクトリを指しうるので、必ず `--show-toplevel` で正規化して
---から基準ディレクトリにする。worktreeのスコープはcwdで決まるため、すべてのgit呼び出しに同じ
---rootを渡すこと。
---@param cwd string|nil
---@return string|nil root 絶対パス（git管理外ならnil）
function M.worktree_root(cwd)
  -- cwd未指定はNeovim自身のカレントディレクトリを指すが、それは `:cd` で動く。キャッシュを
  -- 空文字で引くと `:cd` 後も前のプロジェクトのルートを返し続けるので、解決してから引く
  local key = (cwd and cwd ~= "") and cwd or vim.fn.getcwd()
  local cached = root_cache[key]
  if cached then
    return cached
  end

  local ok, result = pcall(function()
    return vim.system({ "git", "rev-parse", "--show-toplevel" }, { cwd = key, text = true }):wait()
  end)
  if not ok or not result or result.code ~= 0 then
    return nil
  end
  local root = vim.trim(result.stdout or "")
  if root == "" then
    return nil
  end
  root_cache[key] = root
  return root
end

---この worktree で git snapshot が使えるか
---@param cwd string|nil
---@return boolean
function M.is_available(cwd)
  return M.worktree_root(cwd) ~= nil
end

---ref名に使えるようhandle_idをサニタイズする
---@param handle_id string
---@return string
local function sanitize(handle_id)
  local safe = tostring(handle_id):gsub("[^%w%-_]", "")
  if safe == "" then
    safe = "anon"
  end
  return safe
end

---ワーキングツリーを1つのcommitオブジェクトとして固める
---
---ユーザーのindexをコピーしてから `git add -A` するので、stat cacheが再利用されて速く、
---かつユーザーのステージング状態は一切変わらない。
---@param root string worktreeルート
---@return string|nil commit SHA
local function snapshot(root)
  -- worktreeでは index は `.git/worktrees/<name>/index` にあるので、パスはgitに聞く
  local idx_result = git({ "git", "rev-parse", "--git-path", "index" }, root)
  local index_path = idx_result and idx_result.code == 0 and vim.trim(idx_result.stdout or "") or nil
  if index_path and index_path ~= "" and index_path:sub(1, 1) ~= "/" then
    index_path = root .. "/" .. index_path
  end

  local tmp_index = vim.fn.tempname() .. ".vibing-index"
  if index_path and index_path ~= "" then
    -- stat cacheの再利用が目的なので、コピーできなくても続行できる（空indexから作り直すだけ）
    pcall(function()
      (vim.uv or vim.loop).fs_copyfile(index_path, tmp_index)
    end)
  end

  local env = vim.tbl_extend("force", { GIT_INDEX_FILE = tmp_index }, GIT_ENV)

  local added = git({ "git", "add", "-A", "--", ".", EXCLUDE_VIBING_DIR }, root, env)
  if not added or added.code ~= 0 then
    vim.fn.delete(tmp_index)
    return nil
  end

  local tree_result = git({ "git", "write-tree" }, root, env)
  vim.fn.delete(tmp_index)
  if not tree_result or tree_result.code ~= 0 then
    return nil
  end
  local tree = vim.trim(tree_result.stdout or "")
  if tree == "" then
    return nil
  end

  local cmd = { "git", "commit-tree", tree, "-m", "vibing snapshot" }
  local head = git({ "git", "rev-parse", "--verify", "--quiet", "HEAD" }, root)
  local head_sha = head and head.code == 0 and vim.trim(head.stdout or "") or nil
  if head_sha and head_sha ~= "" then
    -- コミット0件（unborn branch）のリポジトリでは親なしで作る
    table.insert(cmd, "-p")
    table.insert(cmd, head_sha)
  end

  local commit = git(cmd, root, GIT_ENV)
  if not commit or commit.code ~= 0 then
    return nil
  end
  local sha = vim.trim(commit.stdout or "")
  return sha ~= "" and sha or nil
end

---`refs/worktree/vibing/` 配下の **十分に古い** 残留refを消す
---
---年齢で足切りするのは、この名前空間がプロセス間で共有されているから。`sessions` も
---`ActiveStreamRegistry` もNeovimプロセス内のテーブルなので、同じworktreeを別のNeovimが
---開いていても、その実行中のリクエストのrefはこちらからは「見覚えのないref」にしか見えない。
---無条件に消すと、走っている他プロセスのgc保険を外してしまう。
---
---実行中のrefは作られてから数秒〜数分で、クラッシュの置き土産はセッションを跨いだ古いもの、
---という差で分ける。閾値はメモリ上のセッションTTLと同じにしてある。読めない日付は消さない
---（安全側）。
---@param root string worktreeルート
local function sweep_refs(root)
  local listed = git(
    { "git", "for-each-ref", "--format=%(refname) %(committerdate:unix)", REF_PREFIX },
    root
  )
  if not listed or listed.code ~= 0 then
    return
  end
  local now = os.time()
  for _, line in ipairs(vim.split(listed.stdout or "", "\n", { trimempty = true })) do
    local ref, created = line:match("^(%S+)%s+(%d+)$")
    if ref and ref:sub(1, #REF_PREFIX) == REF_PREFIX and now - tonumber(created) > SESSION_TTL_SEC then
      git({ "git", "update-ref", "-d", ref }, root)
    end
  end
end

---TTL超過した放置セッションを破棄
local function sweep_stale()
  local now = os.time()
  for handle_id, s in pairs(sessions) do
    if now - s.created > SESSION_TTL_SEC then
      if s.ref then
        git({ "git", "update-ref", "-d", s.ref }, s.root)
      end
      sessions[handle_id] = nil
    end
  end
end

---ベースラインを遅延取得する（PreToolUseフックの許可パスから呼ぶ。2回目以降はno-op）
---
---リクエスト開始時ではなく「最初の変更しうるツール」の時点で取るので、読み取りだけのターンは
---コストゼロになる。
---@param handle_id string|nil リクエストのハンドルID
---@param cwd string|nil セッションのworking_dir
---@param tool_name string ツール名
function M.ensure_baseline(handle_id, cwd, tool_name)
  if not handle_id or handle_id == "" then
    return
  end
  if sessions[handle_id] then
    return
  end
  if tool_name and NON_MUTATING_TOOLS[tool_name] then
    return
  end

  local root = M.worktree_root(cwd)
  if not root then
    return
  end

  sweep_stale()

  -- `refs/worktree/` はgitのper-worktree名前空間なので、起動時の `M.sweep(nil)` はNeovimの
  -- cwdがあるworktreeしか掃除できない（実測: メインworktreeで `for-each-ref` してもlinked
  -- worktree側のrefは列挙されず、実体も `.git/worktrees/<name>/refs/` にある）。チャットは
  -- `.vibing/worktrees/<branch>/` で走るのが普通の運用なので、そこでクラッシュした分のrefは
  -- 起動時掃除では永久に残る。そのworktreeで最初にベースラインを取るときに一度だけ掃除する。
  --
  -- 掃除が走るのはそのrootで最初のベースラインのときだけ。同一プロセス内では、その時点で
  -- そのrootに生きているセッションは定義上まだ無い（2つ目以降はここを素通りする）。
  -- 別プロセスのNeovimが同じworktreeで走っている場合はその限りではないので、sweep_refs側で
  -- 年齢による足切りをしている。
  if not swept_roots[root] then
    swept_roots[root] = true
    sweep_refs(root)
  end

  local base = snapshot(root)
  if not base then
    return
  end

  -- refは「リクエスト中に `git gc` が走ってもオブジェクトが消えない」ための保険にすぎない。
  -- 作れなくても（refs/worktree/ を知らないgit 2.23未満など）スナップショット自体は成立する
  -- ので、失敗は握りつぶして続行する。作れたときだけclear()の削除対象になる。
  local ref = REF_PREFIX .. sanitize(handle_id)
  local updated = git({ "git", "update-ref", ref, base }, root)
  if not updated or updated.code ~= 0 then
    ref = nil
  end

  -- 「同じworktreeで別のリクエストが走っていたか」は、**この時点で** 記録しなければならない。
  --
  -- 判定を差分生成時のレジストリ照会だけに任せると、片側しか安全に倒れない。2つのターンが
  -- 重なったとき、先に終わった方は相手をまだactiveとして見つけてフォールバックできるが、
  -- 後に終わった方が見るころには相手はunregister済みで「重なりは無かった」と読んでしまう。
  -- ところが後者のウィンドウ（自分のベースライン〜自分の差分生成）にはまさに相手の変更が
  -- 入っているので、他人の`sed -i`を自分のターンの成果として書くのはむしろこちら側になる。
  --
  -- セッションはベースライン取得からclear()まで生きており、それは差分が対象とする区間そのもの
  -- なので、ここで「今開いている同じrootのセッション」を見れば区間の重なりが分かる。見つけた
  -- 相手にも印を付けることで、相手が先に終わっていても対称に倒れる。
  local overlapped = false
  for _, other in pairs(sessions) do
    if other.root == root then
      overlapped = true
      other.overlapped = true
    end
  end

  sessions[handle_id] = {
    root = root,
    base = base,
    ref = ref,
    created = os.time(),
    overlapped = overlapped,
  }
end

---このリクエストでスナップショットのベースラインを取得済みか
---@param handle_id string|nil
---@return boolean
function M.has_baseline(handle_id)
  return handle_id ~= nil and sessions[handle_id] ~= nil
end

---このリクエストの書き込みウィンドウが、同じworktreeの別のリクエストと重なっていたか
---
---trueなら、ツリー差分はどちらのターンの成果か区別できない。相手がすでに終わっていても
---trueのままなので、重なった2つのターンは両方ともフォールバックする。
---@param handle_id string|nil
---@return boolean
function M.had_overlap(handle_id)
  local s = handle_id and sessions[handle_id] or nil
  return s ~= nil and s.overlapped == true
end

---ベースラインを取ったworktreeルート
---@param handle_id string|nil
---@return string|nil
function M.get_root(handle_id)
  local s = handle_id and sessions[handle_id] or nil
  return s and s.root or nil
end

---リクエストの差分を生成する
---@param handle_id string|nil リクエストのハンドルID
---@param extra_paths table<string, boolean>|nil ツールイベント由来の変更ファイル（補完用）
---@return string[] files 変更ファイルの相対パス一覧（表示用、worktreeルート相対）
---@return string[] abs_files 絶対パス一覧（バッファリロード用）
---@return string|nil patch_content
---@return boolean ok 差分を取れたか。falseは「変更が無かった」ではなく「**分からなかった**」で、
---  2回目のスナップショットやdiff呼び出しが失敗した場合。呼び出し側はこれを見て request_diff の
---  バックアップに退避できる（そちらはこの時点ではまだ捨てられていない）
function M.generate(handle_id, extra_paths)
  local files = {}
  local abs_files = {}
  local patch_content = nil
  local seen = {}
  local ok = false

  local s = handle_id and sessions[handle_id] or nil
  if s then
    local after = snapshot(s.root)
    if after then
      -- 末尾改行なし・バイナリ・削除・リネームはすべてgitが正しく出す。request_diff.luaの
      -- git_no_index_hunks相当の回避策は要らない
      local diff = git({
        "git",
        "-c",
        "core.quotePath=false",
        "diff",
        "--binary",
        "-M",
        s.base,
        after,
        "--",
        ".",
        EXCLUDE_VIBING_DIR,
      }, s.root)
      ok = diff ~= nil and diff.code == 0
      if ok then
        local out = diff.stdout or ""
        if vim.trim(out) ~= "" then
          -- 先頭のbase行は既存の `gd` フォールバック（patch_viewer）との互換のため。
          -- パスはrepoルート相対なので `git apply -p1`（cwd = worktreeルート）でそのまま
          -- 適用・逆適用できる
          patch_content = string.format("# vibing-request-diff base: %s\n%s", s.root, out)
        end
      end

      -- ファイル名を **patch本文から抜かずに** もう一度gitに聞くのは、意図的な2回目の呼び出し。
      --
      -- patch本文をparseする案は安く見えて成立しない。`+++ b/…` 行を読む方式は、バイナリ・
      -- リネームのみ・モード変更のみの3種類で **その行自体が出力されない** ので、変更を静かに
      -- 落とす（実測: `GIT binary patch` / `rename from|to` / `old mode|new mode` のいずれも
      -- `---`/`+++` を伴わない）。`diff --git a/X b/Y` 行を読む方式は、パスに空白があると
      -- 区切りが一意に決まらない（`ui/patch_viewer/parser.lua` の正規表現が持つ弱点そのもの）。
      -- どちらも「Modified Files から静かに消える」という、この機構が無くそうとしている失敗の形。
      --
      -- そして重複コストは小さい。ここで比較しているのは2つの **ツリーオブジェクト** で、
      -- ワーキングツリーの走査ではないうえ、`--name-only` はhunk生成をしない。9000ファイルの
      -- リポジトリで patch本文が3ms、この呼び出しは2ms、対して支配項の `git add -A` は1回20ms
      -- （ターンあたり2回）。全体の4%程度にしかならない。
      --
      -- 何も変わらなかったターンでは、そのpatch本文が空であること自体が「変更ファイル0件」の
      -- 十分な答えなので、2回目は丸ごと省く。`Bash("ls")` のように「変更しうるツールが動いたが
      -- 何も書かなかった」ターンは普通に起きる。
      -- `cond and nil or git(...)` とは書けない。Luaでは真の枝がnilになると or 側が評価され、
      -- 省いたつもりの呼び出しが必ず走る
      local names = nil
      local nothing_changed = patch_content == nil and diff ~= nil and diff.code == 0
      if not nothing_changed then
        names = git({
          "git",
          "-c",
          "core.quotePath=false",
          "diff",
          "--name-only",
          -- patch本文側と同じ `-M` を付ける。付けないと、`diff.renames=false` を設定している
          -- ユーザーの環境で純粋なリネームが「patchでは1件(rename)、一覧では2件(delete+add)」に
          -- 割れる（実測）。一覧に載った消えた側のパスはリロード対象にもなってしまう
          "-M",
          s.base,
          after,
          "--",
          ".",
          EXCLUDE_VIBING_DIR,
        }, s.root)
      end
      if names and names.code == 0 then
        for _, rel in ipairs(vim.split(names.stdout or "", "\n", { trimempty = true })) do
          if rel ~= "" and not seen[rel] then
            seen[rel] = true
            table.insert(files, rel)
            table.insert(abs_files, s.root .. "/" .. rel)
          end
        end
      end
    end
  end

  -- git差分に現れないのにツールイベントには出ているファイルは `.gitignore` 対象の可能性が高い。
  -- 一覧にだけ載せてpatchセクションは作らない（request_diff.generateと同じ扱い）
  local base_dir = s and s.root or nil
  for path in pairs(extra_paths or {}) do
    local abs = vim.fn.fnamemodify(path, ":p"):gsub("/$", "")
    local rel = abs
    if base_dir then
      local prefix = base_dir .. "/"
      if abs:sub(1, #prefix) == prefix then
        rel = abs:sub(#prefix + 1)
      end
    end
    if not seen[rel] then
      seen[rel] = true
      table.insert(files, rel)
      table.insert(abs_files, abs)
    end
  end

  return files, abs_files, patch_content, ok
end

---refとセッション状態を破棄する（レスポンス処理の最後に必ず呼ぶ）
---
---`git gc` は実行しない。refを外したオブジェクトはdanglingになり、`gc.pruneExpire`（既定2週間）を
---過ぎた時点で通常の `git gc --auto` が回収する。
---@param handle_id string|nil
function M.clear(handle_id)
  if not handle_id then
    return
  end
  local s = sessions[handle_id]
  if not s then
    return
  end
  if s.ref then
    git({ "git", "update-ref", "-d", s.ref }, s.root)
  end
  sessions[handle_id] = nil
end

---プラグイン起動時に、前回クラッシュ等で残ったrefを掃除する
---起動時点でアクティブなリクエストは存在しないので無条件に消してよい。
---@param cwd string|nil
function M.sweep(cwd)
  local root = M.worktree_root(cwd)
  if not root then
    return
  end
  swept_roots[root] = true
  sweep_refs(root)
end

---テスト用: キャッシュとセッション状態を捨てる
function M._reset()
  sessions = {}
  root_cache = {}
  swept_roots = {}
end

M._REF_PREFIX = REF_PREFIX
M._NON_MUTATING_TOOLS = NON_MUTATING_TOOLS

return M
