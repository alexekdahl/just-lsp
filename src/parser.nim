## Justfile parser.  Produces an AST with source spans and errors.

## The parser consumes a complete justfile and produces a simple
## abstract syntax tree (AST) consisting of variable and recipe
## definitions.  Each AST node stores the location of the name and
## optional value or dependencies via ``TextSpan`` so that other
## modules can easily map back to the original text.  A list of
## ``ParseError`` objects records problems encountered during
## parsing.  The implementation is designed to be fast and allocate
## minimally by reusing spans into the original string rather than
## duplicating substrings.  This module depends only on the standard
## library.

import std/[strutils, options]

type
  TextSpan* = object
    ## ``a`` and ``b`` are absolute indices into the source string.  ``b``
    ## is inclusive so that slicing with ``a .. b`` yields the text.
    a*: int  ## absolute start index
    b*: int  ## absolute end index (inclusive)

  ParseError* = object
    line*: int
    col*: int
    message*: string

  AstKind* = enum akVariable, akRecipe

  AstNode* = ref object
    kind*: AstKind
    name*: TextSpan
    line*: int
    col*: int
    value*: Option[TextSpan]
    deps*: seq[TextSpan]
    body*: seq[TextSpan]

  ParseResult* = object
    text*: string
    ast*: seq[AstNode]
    errors*: seq[ParseError]
    lineStarts*: seq[int]

## Extract the substring represented by ``span`` from ``text``.
proc spanText*(span: TextSpan, text: string): string =
  if span.a <= span.b and span.a >= 0 and span.b < text.len:
    text[span.a .. span.b]
  else:
    ""

## Parse a justfile into a list of AST nodes and errors.  The parser
## recognizes two top‑level constructs: variables (``name := value``)
## and recipes (``name: deps`` followed by indented commands).  Any
## unrecognized line is reported as an error.
proc parseJustfile*(text: string): ParseResult =
  var res: ParseResult
  res.text = text

  # Precompute the start index of each line.  ``lineStarts`` stores
  # the character index of the beginning of every line so that AST
  # nodes can map line numbers back into the source string quickly.
  var lineStarts: seq[int] = @[0]
  for i in 0 ..< text.len:
    if text[i] == '\n':
      lineStarts.add(i + 1)
  res.lineStarts = lineStarts

  var current: AstNode = nil
  for li in 0 ..< lineStarts.len:
    let start = lineStarts[li]
    let stop  = (if li+1 < lineStarts.len: lineStarts[li+1]-1 else: text.len-1)
    if start > stop:
      continue

    let line = text[start .. stop]
    let trimmed = line.strip()
    if trimmed.len == 0 or trimmed.startsWith("#"):
      continue

    # Variable definitions.  Require something before the ``:=``.
    if trimmed.contains(":="):
      let sepLocal = line.find(":=")
      if sepLocal <= 0:
        res.errors.add(ParseError(line: li, col: 0, message: "Malformed variable"))
        current = nil
        continue
      let nameRaw = line[0 ..< sepLocal].strip()
      let nameLocal = line.find(nameRaw)
      let node = AstNode(kind: akVariable,
        name: TextSpan(a: start+nameLocal, b: start+nameLocal+nameRaw.len-1),
        line: li, col: nameLocal,
        value: some(TextSpan(a: start+sepLocal+2, b: stop)))
      res.ast.add(node)
      current = nil
      continue

    # Recipe definitions.  Names cannot be empty and may be followed by
    # space‑separated dependencies.
    if ":" in trimmed:
      let sepLocal = line.find(":")
      if sepLocal <= 0:
        res.errors.add(ParseError(line: li, col: 0, message: "Malformed recipe"))
        current = nil
        continue
      let nameRaw = line[0 ..< sepLocal].strip()
      let nameLocal = line.find(nameRaw)
      var deps: seq[TextSpan] = @[]
      let rest = line[(sepLocal+1) .. ^1]
      var i = 0
      # Skip whitespace, then accumulate non‑whitespace tokens as
      # dependency names.  ``isSpaceAscii`` is used instead of the
      # removed ``isSpace``; it tests for ASCII whitespace only.
      while i < rest.len:
        while i < rest.len and rest[i].isSpaceAscii():
          inc i
        let startTok = i
        while i < rest.len and not rest[i].isSpaceAscii():
          inc i
        let endTok = i
        if endTok > startTok:
          let dAbsStart = start + (sepLocal+1) + startTok
          deps.add(TextSpan(a: dAbsStart, b: dAbsStart+(endTok-startTok)-1))
      let node = AstNode(kind: akRecipe,
        name: TextSpan(a: start+nameLocal, b: start+nameLocal+nameRaw.len-1),
        line: li, col: nameLocal,
        deps: deps, body: @[])
      res.ast.add(node)
      current = node
      continue

    # Indented lines belong to the body of the current recipe.  Any
    # indented line outside of a recipe is an error.
    if line.len > 0 and line[0].isSpaceAscii():
      if current != nil and current.kind == akRecipe:
        current.body.add(TextSpan(a: start, b: stop))
      else:
        res.errors.add(ParseError(line: li, col: 0, message: "Command not inside recipe"))
      continue

    # Otherwise the line is unrecognized.
    res.errors.add(ParseError(line: li, col: 0, message: "Unrecognized line"))
    current = nil
  res
