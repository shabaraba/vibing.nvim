---
name: nvim-lsp-navigation
description: Use when navigating or analyzing a codebase that's open in a running Neovim instance via vibing.nvim with an LSP client attached. Prefers the vibing-nvim MCP LSP tools (definitions, references, hover, diagnostics, symbols, call hierarchy) over text search for "where is X defined/used/called", "what type is this", "what's broken here" style questions, since they reflect language-aware, live analysis rather than a text match.
user-invocable: false
---

# Neovim LSP Navigation

Text search (`Grep`/`Glob`) finds string matches; a language server understands imports,
overloads, generics, and cross-file symbol resolution. When `vibing-nvim` MCP tools are
available and the target filetype has an LSP client attached, prefer LSP-backed answers.

## Tool mapping

| Question                                  | Tool                                                 |
| ----------------------------------------- | ---------------------------------------------------- |
| Where is this symbol defined?             | `mcp__vibing-nvim__nvim_lsp_definition`              |
| Where is this symbol used?                | `mcp__vibing-nvim__nvim_lsp_references`              |
| What type/doc does this have?             | `mcp__vibing-nvim__nvim_lsp_hover`                   |
| What are the errors/warnings here?        | `mcp__vibing-nvim__nvim_diagnostics`                 |
| What symbols exist in this file?          | `mcp__vibing-nvim__nvim_lsp_document_symbols`        |
| What's the underlying type of this alias? | `mcp__vibing-nvim__nvim_lsp_type_definition`         |
| Who calls this function?                  | `mcp__vibing-nvim__nvim_lsp_call_hierarchy_incoming` |
| What does this function call?             | `mcp__vibing-nvim__nvim_lsp_call_hierarchy_outgoing` |

## Workflow

1. LSP tools operate on a loaded buffer, not an arbitrary path. If the target file isn't open,
   load it in the background first with `mcp__vibing-nvim__nvim_load_buffer` (returns `bufnr`) —
   this doesn't disrupt the user's current window/view.
2. Pass that `bufnr` plus 1-indexed `line` / 0-indexed `col` to the LSP tool for the exact symbol
   position.
3. Surface relevant `nvim_diagnostics` results before proposing a fix for a file you're editing.
4. Fall back to `Grep`/`Glob` for things LSP doesn't cover: string/comment search, config files,
   non-code text, or a filetype with no attached LSP client (an empty/error result from an LSP
   tool is a signal to fall back, not to retry).
