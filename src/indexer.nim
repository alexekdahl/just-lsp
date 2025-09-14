## Symbol index builder for Justfile AST.

## This module constructs an index of symbols defined in a justfile.
## Variables and recipes are collected into hash tables keyed by name.
## Each definition records its kind, name span and line/column so that
## navigation requests can be served quickly by the language server.

import std/[tables]
import parser

type
  SymKind* = enum skVar, skRecipe

  SymDef* = object
    kind*: SymKind
    nameSpan*: TextSpan
    line*: int
    col*: int

  SymIndex* = object
    recipesByName*: Table[string, seq[SymDef]]
    varsByName*: Table[string, seq[SymDef]]

## Build a symbol index from a parse result.  Iterates over all AST
## nodes and inserts definitions into the appropriate table.
proc buildIndex*(pr: ParseResult): SymIndex =
  var idx: SymIndex
  idx.recipesByName = initTable[string, seq[SymDef]]()
  idx.varsByName = initTable[string, seq[SymDef]]()
  for node in pr.ast:
    let nm = spanText(node.name, pr.text)
    if nm.len == 0:
      continue
    let def = SymDef(kind: (if node.kind == akRecipe: skRecipe else: skVar),
      nameSpan: node.name, line: node.line, col: node.col)
    if node.kind == akRecipe:
      idx.recipesByName.mgetOrPut(nm, @[]).add(def)
    else:
      idx.varsByName.mgetOrPut(nm, @[]).add(def)
  idx