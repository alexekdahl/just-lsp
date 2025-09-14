## Entry point for Justfile LSP.

## This module wires together the JSON‑RPC transport and the LSP
## server.  It repeatedly reads messages from standard input,
## dispatches them via the language server and writes any responses
## back to standard output.  When the server enters the shutting down
## state it exits the main loop.

import std/options
import jsonrpc
import rpcdispatcher
import lspserver

proc main() =
  let conn = newRpcConnection()
  let server = newLspServer()
  for msg in conn.messages():
    let resp = server.dispatcher.dispatch(msg)
    if resp.isSome:
      conn.sendMessage(resp.get())
    if server.shuttingDown:
      break

when isMainModule:
  main()
