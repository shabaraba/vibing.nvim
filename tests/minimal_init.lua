-- Minimal init.lua for running tests
-- Sets up plenary and vibing.nvim for testing

-- Add vibing.nvim to runtimepath, resolved from this script's own path rather than from ".".
--
-- The comment here used to say "always absolute when invoked via `-u <abs path>`". It is not:
-- every script in package.json passes `-u tests/minimal_init.lua`, a relative path, so `:p`
-- resolves against the **process cwd**. That happens to give the right answer, because Neovim
-- could only have found a relative `-u` from a directory that already holds `tests/`. What it
-- does not give is any protection against running the suite from a different checkout of this
-- repository: the cwd decides which tree is tested, end to end, and nothing here can tell that
-- the caller meant another one.
--
-- Which is why the plugin root is printed below. A suite run against the wrong checkout passes,
-- reporting on code the developer did not change; the one thing that turns that from silent into
-- visible is saying out loud which tree was loaded.
local this_file = debug.getinfo(1, "S").source:sub(2)
local plugin_root = vim.fn.fnamemodify(this_file, ":p:h:h")
vim.opt.runtimepath:append(plugin_root)

-- Add plenary to runtimepath
local plenary_path = vim.fn.stdpath("data") .. "/site/pack/vendor/start/plenary.nvim"
if vim.fn.isdirectory(plenary_path) == 1 then
  vim.opt.runtimepath:append(plenary_path)
end

-- Check plenary is available
local ok, plenary = pcall(require, "plenary")
if not ok then
  print("plenary.nvim is required for testing")
  print("Install it with your package manager")
  os.exit(1)
end

-- Basic vim setup for tests
vim.opt.swapfile = false
vim.opt.backup = false

-- ShaDaを一切読み書きしない。
--
-- `PlenaryBustedDirectory` はspecファイルごとに子Neovimを起動するので、スイート1回で100以上の
-- プロセスが同じ ShaDa ファイルを同時に読み書きする。`vim.fn.bufload()` はマーク復元のために
-- ShaDa を読むため、書き込み途中のファイルに当たると
-- `E576: Reading ShaDa file: last entry specified that it occupies N bytes, but file ended earlier`
-- で **specが落ちる**。落ちるファイルは実行ごとに変わり、単体では必ず通るので、コードの不具合と
-- 見分けがつかない偽陽性になる。
--
-- テストがユーザーのShaDa（コマンド履歴・マーク・レジスタ）を読む理由も、汚す理由も無い。
vim.opt.shadafile = "NONE"

print("Test environment initialized: " .. plugin_root)
