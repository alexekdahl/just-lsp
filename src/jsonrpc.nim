## JSON‑RPC transport layer over streams (stdio by default).
## Handles message framing, parsing, and sending.

## This module implements a minimal JSON‑RPC transport on top of Nim's
## stream API.  It is responsible for framing messages using the
## ``Content‑Length`` header and for parsing incoming JSON.  The code
## has been written to work with Nim 2.0.  In particular ``stdin`` and
## ``stdout`` are of type ``File`` in Nim 2.0 and cannot be used
## directly as ``Stream`` objects.  To support arbitrary stream
## sources (files, sockets, string streams, etc.) the constructor
## accepts optional ``Stream`` parameters and will transparently
## convert ``stdin`` and ``stdout`` to file streams when needed.  The
## use of the high level ``streams`` API also avoids deprecated
## low‑level procs like ``readBuffer`` which only operate on ``File``.

import std/[json, strutils, streams, options]

type
  RpcError* = object of CatchableError
    ## Raised if incoming JSON is invalid.

  RpcConnection* = ref object
    ## Represents a bidirectional JSON‑RPC connection.  ``inStream`` and
    ## ``outStream`` are abstract streams provided by Nim's standard
    ## library.  A reusable string buffer is used to accumulate
    ## message payloads.
    inStream: Stream
    outStream: Stream
    buffer: string  ## Reusable message buffer

## Create a new JSON‑RPC connection using the given streams.  When
## called without arguments the standard input and output are wrapped
## into ``FileStream`` objects.  Explicit streams may be supplied
## instead of the defaults to connect the RPC layer to sockets or
## other sources.
proc newRpcConnection*(inStream: Stream = nil, outStream: Stream = nil): RpcConnection =
  var istream = inStream
  var ostream = outStream
  # When no input stream was provided convert ``stdin`` to a stream.
  if istream.isNil:
    istream = newFileStream(stdin)
  # When no output stream was provided convert ``stdout`` to a stream.
  if ostream.isNil:
    ostream = newFileStream(stdout)
  RpcConnection(inStream: istream, outStream: ostream, buffer: "")

## Read one JSON‑RPC message.  Returns ``none`` if EOF is reached or
## the payload is malformed.  The function first consumes header
## lines until an empty line is encountered, extracts the
## ``Content‑Length`` header and then reads that many bytes from
## ``inStream`` into the reusable ``buffer``.  The resulting byte
## sequence is decoded as UTF‑8 JSON.  Header names are treated
## case‑insensitively and a trailing carriage return (\r) is ignored
## in accordance with the JSON‑RPC/LSP specification.
proc readMessage*(conn: RpcConnection): Option[JsonNode] =
  var line: string
  var contentLength = 0

  # Read header lines until a blank line.  Bail early on EOF.
  while true:
    if conn.inStream.atEnd():
      return none(JsonNode)
    # ``readLine`` fills ``line`` and returns true when a line was read.
    if not conn.inStream.readLine(line):
      return none(JsonNode)
    # Strip trailing carriage returns (for CRLF) and surrounding whitespace.
    let headerLine = line.strip()
    # An empty line indicates the end of the headers.
    if headerLine.len == 0:
      break
    # Split header on the first colon and parse known fields.
    let parts = headerLine.split(":", 1)
    if parts.len == 2:
      let name = parts[0].strip().toLowerAscii()
      let value = parts[1].strip()
      if name == "content-length":
        try:
          contentLength = parseInt(value)
        except ValueError:
          contentLength = 0
      # Unknown headers (e.g. Content-Type) are ignored.

  # If no valid content length was provided return none.
  if contentLength <= 0:
    return none(JsonNode)
  # Ensure the buffer is large enough to hold the payload.  Avoid
  # repeatedly allocating new strings on every message which would
  # degrade performance.
  if conn.buffer.len < contentLength:
    conn.buffer.setLen(contentLength)

  # Read exactly ``contentLength`` bytes of JSON data.  ``readData``
  # returns the number of bytes read; discard the return value.  The
  # payload remains in the beginning of ``conn.buffer``.
  discard conn.inStream.readData(addr conn.buffer[0], contentLength)
  let payload = conn.buffer[0 ..< contentLength]

  try:
    some(parseJson(payload))
  except JsonParsingError as e:
    raise newException(RpcError, "Invalid JSON: " & e.msg)

## Send a JSON‑RPC message.  The payload is converted to a string
## representation and preceded by a ``Content‑Length`` header.  The
## output stream is flushed to ensure timely delivery.
proc sendMessage*(conn: RpcConnection, msg: JsonNode) =
  let s = $msg
  conn.outStream.write("Content-Length: " & $s.len & "\r\n\r\n")
  conn.outStream.write(s)
  conn.outStream.flush()

## Iterate all incoming JSON‑RPC messages.  This convenience
## iterator repeatedly calls ``readMessage`` until it returns ``none``.
iterator messages*(conn: RpcConnection): JsonNode =
  var msg = conn.readMessage()
  while msg.isSome:
    yield msg.get()
    msg = conn.readMessage()