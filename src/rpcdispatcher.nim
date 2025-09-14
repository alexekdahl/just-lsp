## JSON‑RPC dispatcher.  Routes messages by method name.

## This module provides a simple dispatcher for JSON‑RPC messages.  It
## maps method names to handlers and differentiates between requests
## (which expect a response) and notifications (which do not).  To
## avoid a dependency on Nim's optional ``std/results`` module—which
## may not be available in some environments—we provide a minimal
## ``Result`` type along with a few helper procs.  Handlers return a
## ``Result`` so that failures can be propagated without raising
## exceptions through the RPC layer.

import std/[json, tables, options]

## A minimal result type.  ``ok`` holds the successful value while
## ``error`` holds the error string for failures.  The boolean
## discriminator ``ok`` distinguishes between the two cases.
type
  ## A simple result type carrying either a value or an error string.
  ## ``ok`` indicates whether the operation succeeded.  When ``ok`` is
  ## true the ``value`` field holds the result; when false the
  ## ``err`` field holds the error message.  We avoid a second generic
  ## parameter for the error type to keep the API simple and to avoid
  ## instantiation issues with Nim's variant objects.
  Result*[T] = object
    ok*: bool
    value*: T
    err*: string

  ## Handler for JSON‑RPC requests.  Receives the ``params`` node and
  ## returns either a JSON result or an error string.
  RequestHandler* = proc (params: JsonNode): Result[JsonNode]

  ## Handler for JSON‑RPC notifications.  Notifications do not return a
  ## response.
  NotificationHandler* = proc (params: JsonNode)

  ## Dispatcher type mapping method names to handlers.  Requests and
  ## notifications are stored in separate tables.
  RpcDispatcher* = ref object
    requests: Table[string, RequestHandler]
    notifications: Table[string, NotificationHandler]

## Construct a successful result.  Named ``okResult`` to avoid
## confusion with the ``ok`` field defined on ``Result``.
proc okResult*[T](value: T): Result[T] =
  Result[T](ok: true, value: value, err: "")

## Construct a failed result.  Named ``errResult`` to avoid naming
## collisions.  The value is initialised to the default value of the
## generic type ``T``.
proc errResult*[T](e: string): Result[T] =
  ## Construct a failed result.  The value is initialised using Nim's
  ## default initialisation for type ``T``.
  var v: T
  Result[T](ok: false, value: v, err: e)

## Query whether a result is successful.  Returns true when the
## ``value`` field is valid.
proc isOkResult*[T](r: Result[T]): bool = r.ok

## Extract the successful value.  It is the caller's responsibility
## to ensure that the result is successful.
proc get*[T](r: Result[T]): T = r.value

## Extract the error message.  It is the caller's responsibility to
## ensure that the result represents a failure.
proc error*[T](r: Result[T]): string = r.err

## Construct a new dispatcher with empty tables.
proc newDispatcher*(): RpcDispatcher =
  ## Initialise an empty dispatcher.  Using a ``result`` variable and
  ## explicit assignments avoids confusing Nim's parser when
  ## instantiating objects with generic type parameters on multiple
  ## lines.
  var d: RpcDispatcher
  new(d)
  d.requests = initTable[string, RequestHandler]()
  d.notifications = initTable[string, NotificationHandler]()
  result = d

## Register a request handler.  Subsequent registrations for the same
## method will overwrite the previous handler.
proc registerRequest*(d: RpcDispatcher, name: string, handler: RequestHandler) =
  ## Register a handler for the given method name.  We use ``name``
  ## instead of ``method`` because ``method`` is a reserved keyword in
  ## Nim and cannot be used as an identifier without confusing the
  ## parser.
  d.requests[name] = handler

## Register a notification handler.  Subsequent registrations for the
## same method will overwrite the previous handler.
proc registerNotification*(d: RpcDispatcher, name: string, handler: NotificationHandler) =
  ## Register a notification handler.  See ``registerRequest`` for
  ## details on naming.
  d.notifications[name] = handler

## Dispatch an incoming JSON‑RPC message.  For requests (calls with an
## ``id``) the appropriate handler is invoked and the returned
## ``Result`` is wrapped in a JSON response.  For notifications (calls
## without an ``id``) the handler is invoked and ``none`` is
## returned.  Unknown methods result in a ``Method not found`` error.
proc dispatch*(d: RpcDispatcher, msg: JsonNode): Option[JsonNode] =
  # If there is no method key we cannot dispatch.
  if not msg.hasKey("method"):
    return none(JsonNode)
  let methName = msg["method"].getStr()
  # Determine whether this is a request (has ``id``) or notification.
  let idPresent = msg.hasKey("id")
  # Extract parameters, defaulting to an empty object if absent.
  let params = if msg.hasKey("params"): msg["params"] else: %*{}

  # Route requests.
  if idPresent and methName in d.requests:
    let res = d.requests[methName](params)
    if res.isOkResult:
      return some(%*{"jsonrpc": "2.0", "id": msg["id"], "result": res.get()})
    else:
      return some(%*{"jsonrpc": "2.0", "id": msg["id"],
        "error": {"code": -32000, "message": "Handler error", "data": res.error}})
  elif not idPresent and methName in d.notifications:
    d.notifications[methName](params)
    return none(JsonNode)

  # Unknown method: return a standard JSON‑RPC error when an ``id`` is
  # present or ignore for notifications.
  if idPresent:
    return some(%*{"jsonrpc": "2.0", "id": msg["id"],
      "error": {"code": -32601, "message": "Method not found: " & methName}})
  none(JsonNode)
