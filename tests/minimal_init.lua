-- Minimal init.lua for running tests
-- Sets up plenary and vibing.nvim for testing

-- Add vibing.nvim to runtimepath.
-- Resolved from this script's own path (always absolute when invoked via `-u <abs path>`),
-- not from the process cwd: E2E specs may spawn the child Neovim with cwd set to a throwaway
-- test repo, in which case "." would not point at the plugin root at all.
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

print("Test environment initialized")
