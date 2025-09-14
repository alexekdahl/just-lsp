## LSP server core for Justfile.
## Implements go‑to‑definition and minimal document lifecycle handling.

## This module builds upon the JSON‑RPC dispatcher to provide a
## Language Server Protocol (LSP) server for the `just` build tool.  It
## manages opened documents, parses and indexes them on change, and
## responds to definition requests from editors.  The implementation
## focuses on correctness and clarity; helpers such as ``lineSlice`` and
## ``wordBounds`` are marked ``inline`` so that performance remains
## competitive even without heavy optimisations.  Additional LSP
## methods can be registered in ``registerCoreMethods``.

import std/[json, tables, options, strutils]
import rpcdispatcher, parser, indexer

type
  ## An in‑memory representation of an open text document.
  TextDocument = object
    uri: string
    text: string
    version: int
    parse: ParseResult
    index: SymIndex

  ## The main server object tying together the dispatcher and the
  ## document store.  ``shuttingDown`` is used to signal when the
  ## ``shutdown`` or ``exit`` notifications have been received.
  LspServer* = ref object
    dispatcher*: RpcDispatcher
    documents*: Table[string, TextDocument]
    shuttingDown*: bool

## Forward declarations of procedures.  These need to be declared
## before ``newLspServer`` to satisfy Nim's name resolution when
## ``newLspServer`` calls them.  The actual implementations appear
## below.
proc registerCoreMethods*(s: LspServer)
proc registerGoToDefinition*(s: LspServer)

## Construct a new LSP server and register the core and
## go‑to‑definition methods.  Other modules may register additional
## handlers on the returned dispatcher.
proc newLspServer*(): LspServer =
  result = LspServer(
    dispatcher: newDispatcher(),
    documents: initTable[string, TextDocument](),
    shuttingDown: false
  )
  # Use free procs instead of method-like syntax.  Calling the
  # procedures directly with ``result`` avoids Nim misinterpreting
  # them as methods (which could lead to “undeclared routine” errors).
  registerCoreMethods(result)
  registerGoToDefinition(result)

## A helper returning the absolute character indices for the start and
## end of a line.  If ``li`` is out of range the returned tuple
## contains (-1, -1).
proc lineSlice(pr: ParseResult; li: int): (int, int) {.inline.} =
  if li < 0 or li >= pr.lineStarts.len:
    return (-1, -1)
  let start = pr.lineStarts[li]
  let stop  = if li+1 < pr.lineStarts.len: pr.lineStarts[li+1]-1 else: pr.text.len-1
  (start, stop)

## Determine the word boundaries around ``col`` in ``line``.  Valid
## characters for symbols include alphanumerics plus underscore and
## dash.  Returns (-1, -1) when no symbol is found at ``col``.
proc wordBounds(line: string; col: int): (int,int) {.inline.} =
  var s = col
  var e = col
  let n = line.len
  if s < 0 or s > n:
    return (-1, -1)
  while s > 0 and (line[s-1].isAlphaNumeric() or line[s-1] in {'_', '-'}):
    dec s
  while e < n and (line[e].isAlphaNumeric() or line[e] in {'_', '-'}):
    inc e
  (s, e)

## Check whether ``col`` is inside a ``{{ ... }}`` brace block.
proc inBraces(line: string; col: int): bool {.inline.} =
  let openIx = line.rfind("{{")
  if openIx < 0:
    return false
  # The closing brace may occur after the current column; restrict the
  # search to simplify the logic.
  let closeIx = line.find("}}", openIx+2)
  closeIx >= 0 and col >= openIx+2 and col <= closeIx

## Determine whether ``col`` lies after the first colon on the line.
proc isHeaderAndAfterColon(line: string; col: int): bool {.inline.} =
  let colonIx = line.find(':')
  colonIx >= 0 and col > colonIx

## Register LSP methods that are not tied to a particular feature.
## Methods registered here include ``initialize``, ``shutdown``,
## ``exit``, and simple text document lifecycle notifications.  The
## server maintains its document map in response to these events.
proc registerCoreMethods*(s: LspServer) =
  ## ``initialize``: return server capabilities and optional server info.
  ## According to the LSP specification the initialize response must
  ## advertise the features the server supports.  This server
  ## advertises full text document synchronization (open/close + full
  ## content on change) and a ``definitionProvider`` so that clients
  ## know that ``textDocument/definition`` is implemented.  We also
  ## declare that positions are encoded using UTF‑16 code units which
  ## matches the default expectation for most clients.  Additional
  ## capabilities may be added here as new features are implemented.
  s.dispatcher.registerRequest("initialize", proc (params: JsonNode): Result[JsonNode] =
    let capabilities = %*{
      "textDocumentSync": %*{ "openClose": true, "change": 1 },
      "definitionProvider": true,
      "positionEncoding": "utf-16"
    }
    let serverInfo = %*{
      "name": "just-lsp",
      "version": "0.1.0"
    }
    okResult(%*{
      "serverInfo": serverInfo,
      "capabilities": capabilities
    })
  )
  # ``shutdown``: mark server as shutting down and return an empty result.
  # After sending a shutdown request the client is expected to send
  # ``exit``.  The server sets the shuttingDown flag and exits the
  # message loop once the current message has been processed.
  s.dispatcher.registerRequest("shutdown", proc (params: JsonNode): Result[JsonNode] =
    s.shuttingDown = true
    okResult(%*{})
  )
  # ``exit`` notification: mark server as shutting down.  According to the
  # specification the server should terminate if ``exit`` is received
  # after ``shutdown``.  If a client sends ``exit`` without a prior
  # ``shutdown`` the server should also terminate gracefully.
  s.dispatcher.registerNotification("exit", proc (params: JsonNode) =
    s.shuttingDown = true
  )
  # ``initialized`` notification: currently a no‑op.  This can be used
  # in the future to send configuration requests back to the client or
  # trigger additional initialisation.
  s.dispatcher.registerNotification("initialized", proc (params: JsonNode) = discard)
  # ``textDocument/didOpen``: add or update a document and index it.
  s.dispatcher.registerNotification("textDocument/didOpen", proc (params: JsonNode) =
    let textDocument = params["textDocument"]
    let uri = textDocument["uri"].getStr()
    let text = textDocument["text"].getStr()
    # Some clients provide version numbers; default to 0 when absent.
    let version = if textDocument.hasKey("version"): textDocument["version"].getInt() else: 0
    let pr = parseJustfile(text)
    let idx = buildIndex(pr)
    s.documents[uri] = TextDocument(uri: uri, text: text, version: version, parse: pr, index: idx)
  )
  # ``textDocument/didChange``: update the text of an existing document.
  # Since we advertise ``TextDocumentSyncKind.Full`` we expect the
  # entire document text in the first entry of ``contentChanges``.
  s.dispatcher.registerNotification("textDocument/didChange", proc (params: JsonNode) =
    let uri = params["textDocument"]["uri"].getStr()
    let changes = params["contentChanges"]
    if changes.len > 0:
      let newText = changes[0]["text"].getStr()
      let pr = parseJustfile(newText)
      let idx = buildIndex(pr)
      s.documents[uri] = TextDocument(uri: uri, text: newText, version: 0, parse: pr, index: idx)
  )
  # ``textDocument/didClose``: remove a document from the map.
  s.dispatcher.registerNotification("textDocument/didClose", proc (params: JsonNode) =
    let uri = params["textDocument"]["uri"].getStr()
    if uri in s.documents:
      s.documents.del(uri)
  )

## Register the go‑to‑definition request.  This handler searches the
## indexed symbols for the word under the cursor and returns all
## matching locations.  The lookup rules follow those of just: within
## ``{{ ... }}`` only variables are considered; on headers after the
## colon only recipes are considered; elsewhere recipes are tried first
## then variables.  When definitions are found the handler returns an
## array of LSP ``Location`` objects with ``uri`` and ``range``.
proc registerGoToDefinition*(s: LspServer) =
  s.dispatcher.registerRequest("textDocument/definition",
    proc(params: JsonNode): Result[JsonNode] =
      let uri = params["textDocument"]["uri"].getStr()
      if uri notin s.documents:
        return errResult[JsonNode]("Document not found")
      let pos = params["position"]
      let li = pos["line"].getInt()
      let co = pos["character"].getInt()
      let doc = s.documents[uri]
      let (ls, le) = lineSlice(doc.parse, li)
      if ls < 0:
        return errResult[JsonNode]("Position out of range")
      let line = doc.text[ls .. le]
      let (ws, we) = wordBounds(line, co)
      if ws < 0:
        return errResult[JsonNode]("No symbol at position")
      let word = line[ws ..< we]
      var locs: seq[JsonNode] = @[]
      if inBraces(line, co):
        if word in doc.index.varsByName:
          for d in doc.index.varsByName[word]:
            locs.add(%*{"uri": uri, "range": {"start": {"line": d.line, "character": d.col}, "end": {"line": d.line, "character": d.col + word.len}}})
      elif isHeaderAndAfterColon(line, co):
        if word in doc.index.recipesByName:
          for d in doc.index.recipesByName[word]:
            locs.add(%*{"uri": uri, "range": {"start": {"line": d.line, "character": d.col}, "end": {"line": d.line, "character": d.col + word.len}}})
      else:
        if word in doc.index.recipesByName:
          for d in doc.index.recipesByName[word]:
            locs.add(%*{"uri": uri, "range": {"start": {"line": d.line, "character": d.col}, "end": {"line": d.line, "character": d.col + word.len}}})
        if locs.len == 0 and word in doc.index.varsByName:
          for d in doc.index.varsByName[word]:
            locs.add(%*{"uri": uri, "range": {"start": {"line": d.line, "character": d.col}, "end": {"line": d.line, "character": d.col + word.len}}})
      if locs.len == 0:
        return errResult[JsonNode]("Definition not found")
      okResult(%*locs)
  )