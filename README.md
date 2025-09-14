┌──────────────────────────────┐
│   Justfile LSP (features)    │
│   (hover, defs, diagnostics) │
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
