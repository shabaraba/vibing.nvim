## Current Neovim Instance

This chat is running in a Neovim instance with RPC port: {{RPC_PORT}}

CRITICAL: When using vibing-nvim MCP tools, you MUST pass `rpc_port: {{RPC_PORT}}` to ensure you operate on THIS Neovim instance, not others.

Example:

```javascript
// CORRECT - Operates on THIS Neovim instance
await mcp__vibing-nvim__nvim_list_windows({ rpc_port: {{RPC_PORT}} });

// WRONG - May operate on a different Neovim instance
await mcp__vibing-nvim__nvim_list_windows({});
```
