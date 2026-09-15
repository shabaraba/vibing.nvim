-- init.lua for the *child* Neovim an E2E spec drives over RPC.
--
-- tests/minimal_init.lua is the parent's init: it wires up plenary so the specs can run. The
-- child needs something different — vibing.nvim actually set up, so `:Vibing*` commands exist at
-- all. Pointing the child at minimal_init left it with no commands, which is why every spec's
-- first `:VibingChat` did nothing.

-- Derived from this file's own location rather than from the child's cwd, because a spec may
-- start the child in a throwaway project directory (plugin_dir_spec does, to get a
-- `.vibing/plugins/` that is not the developer's real one). `getcwd()` would then add the wrong
-- directory and no `:Vibing*` command would exist.
local repo_root = vim.fs.root(debug.getinfo(1, "S").source:sub(2), "package.json") or vim.fn.getcwd()
vim.opt.runtimepath:append(repo_root)

vim.opt.swapfile = false
vim.opt.backup = false

-- Chats go to a per-child temp directory. The default ("project") writes into the repository's
-- own .vibing/chat/, so running the suite used to leave real chat files behind — in CI, in a
-- checkout, every time.
--
-- The path comes from the parent (spawn_nvim_instance sets $VIBING_E2E_CHAT_DIR) so that cleanup
-- never has to ask this process where it wrote; rpcrequest has no timeout, and a wedged child
-- would otherwise hang the suite. The fallback keeps this init usable when run by hand.
local chat_dir = vim.env.VIBING_E2E_CHAT_DIR
if not chat_dir or chat_dir == "" then
  chat_dir = vim.fn.tempname() .. "/chat"
end
vim.fn.mkdir(chat_dir, "p")

-- One definition, shared with `e2e_helper.setup_child`: a spec that re-runs setup() to change a
-- setting has to keep the rest of this, because setup() replaces the whole options table rather
-- than merging onto what is already there.
--
-- The backend arrives the same way the chat directory does, so a spec that wants one does not
-- have to configure this child a second time after it has already started.
local adapter = vim.env.VIBING_E2E_ADAPTER
local overrides = (adapter and adapter ~= "") and { adapter = adapter } or nil

require("vibing").setup(require("vibing.testing.e2e_helper").child_config(chat_dir, overrides))
