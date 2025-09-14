# Justfile LSP

Language Server for `just` files, written in Nim.
Right now it’s small and focused. It speaks JSON-RPC/LSP over stdio, parses a single justfile buffer, and answers a couple of core queries.

```
┌──────────────────────────────┐
│   Justfile LSP (features)    │
│   (hover, defs)              │
└──────────────┬───────────────┘
               │
┌──────────────┴───────────────┐
│ JSON-RPC Dispatcher / Router │
│   (maps "method" → handler)  │
└──────────────┬───────────────┘
               │
┌──────────────┴───────────────┐
│   JSON-RPC Transport Layer   │
│ (framing, I/O, buffering)    │
└──────────────────────────────┘
```

## Status

- **Implemented**
  - Transport: JSON-RPC over stdio (`Content-Length` framing).
  - Core LSP: `initialize`, `initialized`, `shutdown`, `exit`.
  - Text sync: `didOpen`, `didChange` (Full), `didClose`.
  - Features:
    - **Go to Definition** (`textDocument/definition`)
    - **Hover** (`textDocument/hover`)
- **Not implemented (yet)**
  - Diagnostics
  - Completion, references, rename, symbols, formatting
  - Workspace/multi-file/project awareness
  - Incremental sync

This is usable for basic navigation in a single justfile. Expect rough edges.

## What “go to definition” and “hover” mean here

- In `{{ ... }}` blocks, identifiers are treated as **variables**.
- In a recipe header (after the first `:`), identifiers are treated as **recipe names**.
- Elsewhere, the server prefers **recipes**, then falls back to **variables**.

Hover shows a simple plaintext tag: `recipe: <name>` or `variable: <name>`, with a range that matches the symbol under the cursor.

### Position encoding

LSP clients use UTF-16 code units. Internally the server works in bytes and converts:
- incoming positions **UTF-16 → bytes**,
- outgoing ranges **bytes → UTF-16**.

## Neovim setup (example)

Using `nvim-lspconfig`:

```lua
-- >>> ADD: Justfile LSP (custom) <<<
-- Ensure Justfiles get the 'just' filetype
pcall(function()
	vim.filetype.add({
		filename = { ["Justfile"] = "just", ["justfile"] = "just" },
		pattern = { [".*/[Jj]ustfile"] = "just" },
	})
end)

local configs = require("lspconfig.configs")
if not configs.justls then
	configs.justls = {
		default_config = {
			-- Replace "justls" with your binary if different
			cmd = { "justls" },
			filetypes = { "just" },
			root_dir = function(fname)
				return require("lspconfig").util.root_pattern("Justfile", "justfile", ".git")(fname)
					or require("lspconfig").util.path.dirname(fname)
			end,
			single_file_support = true,
		},
	}
end

lspconfig.justls.setup({
	capabilities = capabilities,
	on_attach = on_attach,
	handlers = handlers,
})
```

## Design notes

- **Transport**: stdio; strict `Content-Length` framing; case-insensitive headers.
- **Sync**: Full text on change (simple and reliable to start with).
- **Indexing**: Built from the open buffer; no cross-file support yet.
- **Heuristics**: A small “snap-left” when the cursor is just past a symbol so hover/defs still work.

## Roadmap (short list)

- Diagnostics (undefined recipe/variable, duplicate names, etc.)
- References / rename / workspace symbols
- Incremental sync
- Better root detection and multi-file awareness
- Smarter hover (show values / dependencies, maybe snippets)

## Caveats

- Single-file minded right now.
- Error messages are minimal.
- The hover text is deliberately plain.

