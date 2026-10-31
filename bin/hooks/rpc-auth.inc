# Session token for one RPC request. Sourced by the hook scripts; not a hook itself.
#
# The file is written by lua/vibing/infrastructure/rpc/comm_dir.lua (mode 0600, inside the 0700
# comm directory). Only [0-9a-f] is emitted, which is what makes it safe to interpolate into the
# caller's JSON printf. Named .inc so bin/hooks/*.sh stays the set of hook entry points
# identity_spec.lua globs.

rpc_auth_token() {
  local dir="$1"
  local file="${dir}/token"
  if [ ! -r "$file" ]; then
    return 0
  fi
  tr -cd '0-9a-f' < "$file" | head -c 128
}
