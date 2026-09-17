--- What distinguishes this Neovim from another one working in the same project.
---
--- Two Neovims open on one repository share every path under `<cwd>/.vibing/`, and most of what
--- goes there is identical for both, so sharing was free. It stopped being free once a file's
--- contents started depending on **this instance's configuration**: the hook settings carry a
--- timeout derived from `permissions.approval_wait_sec` (`hooks/wait_budget.lua`), and a second
--- Neovim with a lower value rewrites the file a resident CLI process of ours may still be reading.
---
--- The failure that would cause is the one this whole area exists to prevent. Our hook's own
--- deadline reaches the CLI child in its environment and is therefore **fixed at spawn**, while the
--- timeout lives in a file that is not — so a rewrite to a smaller number puts the CLI's deadline
--- *ahead* of the script's, which is exactly the ordering under which every CLI measured
--- **fails open** and runs the tool with no verdict.
---
--- It is removed rather than detected. Whether a given CLI re-reads its settings per turn is a fact
--- about that CLI, unmeasured, and four backends' worth of it; a per-instance filename makes the
--- question not arise. The same key `comm_dir` already uses, for the same reason.
--- @module vibing.infrastructure.rpc.instance_key

local M = {}

--- The key for this Neovim.
---
--- The RPC port when there is one, because that is already how a CLI child is bound back to the
--- instance that launched it. Without a port, the process id — two portless instances still must
--- not collide, and nothing of ours is listening for either of them anyway.
--- @return string
function M.get()
  local ok, rpc_server = pcall(require, "vibing.infrastructure.rpc.server")
  if ok then
    local port = rpc_server.get_port()
    if port and port ~= 0 then
      return tostring(port)
    end
  end
  return "0-" .. vim.fn.getpid()
end

--- Pattern matching any instance's key inside a generated file or directory name.
---
--- A Lua pattern, not a regex: `-` is a quantifier, so the portless form's literal one is escaped.
M.PATTERN = "[%d]+%-?[%d]*"

--- Every key that currently belongs to a running Neovim, this one included.
---
--- Used to decide whether a leftover file is ours to delete. Errs towards *keeping* things: a
--- registry that cannot be read returns only this instance's key, and the sweep that consumes this
--- is written to skip rather than guess.
---
--- Portless instances are not in the registry at all, so their leftovers are not protected here.
--- That is the same gap `hook_cleanup` documents for comm directories, and it is harmless for the
--- same reason: without a port no CLI child of theirs is bound to anything.
--- @return table<string, boolean>
function M.live()
  local live = { [M.get()] = true }
  local ok, instances = pcall(function()
    return require("vibing.infrastructure.rpc.registry").list()
  end)
  if ok and instances then
    for _, instance in ipairs(instances) do
      if instance.port then
        live[tostring(instance.port)] = true
      end
    end
  end
  return live
end

--- Directories already swept this session, keyed by directory *and* pattern.
---
--- Once per directory is enough: the sweep exists only to stop dead instances' leftovers piling up,
--- and the generators that call it run on every spawn, where a scandir per turn would be
--- synchronous I/O on the main loop for no benefit.
--- @type table<string, boolean>
local swept = {}

--- Delete the per-instance leftovers of Neovims that are no longer running.
---
--- **Skips rather than guesses.** A name whose key does not match, or a key belonging to a live
--- instance, is left alone — deleting a live instance's hook settings takes its permission gate
--- with it on that instance's next spawn, which fails open.
--- @param dir string the directory to scan
--- @param name_pattern string a Lua pattern over one entry's name with exactly one capture, the key
--- @param remove fun(path: string) how to delete one entry (a file and a directory differ)
function M.sweep(dir, name_pattern, remove)
  local memo = dir .. "\0" .. name_pattern
  if swept[memo] then
    return
  end
  swept[memo] = true

  local ok, entries = pcall(vim.fn.readdir, dir)
  if not ok or not entries then
    return
  end

  local live = M.live()
  for _, name in ipairs(entries) do
    local key = name:match(name_pattern)
    if key and not live[key] then
      pcall(remove, dir .. "/" .. name)
    end
  end
end

--- Test seam: `sweep` is memoized, so a spec exercising it twice needs the memo cleared.
--- Production code has no reason to call this.
function M._forget_swept()
  swept = {}
end

return M
