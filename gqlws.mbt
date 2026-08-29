///|
/// The `graphql-transport-ws` subprotocol (the wire protocol GraphiQL and the
/// `graphql-ws` client library speak, and what strawberry serves) over the
/// moonasgi WebSocket seam. A `WebSocketHandler` whose `on_receive` folds each
/// inbound control message into the frames a server sends back:
///
/// - `connection_init` -> `connection_ack` (a second init closes with 4429)
/// - `ping` -> `pong` (echoing any payload)
/// - `subscribe` -> a run of `next` messages, one per event, then `complete`;
///   a request that fails to start (parse/validation/no-source) yields a single
///   `error` message instead, per the spec's distinction between a request error
///   and an execution result
/// - `complete` (client) -> accepted; the operation is already finished
///
/// A `subscribe` before `connection_init` closes with 4401, a reused operation
/// id closes with 4409 (ids are single-use per connection), and a binary frame
/// or an unparseable message closes with 4400.
///
/// The source is the synchronous pull stream from `create_source_event_stream`,
/// so a subscription's events are delivered as an ordered `next` run followed by
/// `complete` — the protocol exactly as a client observes it, testable on every
/// backend through the moonasgi `TestClient` without an async runtime. A live
/// async source (an infinite stream that blocks between events) is the async
/// native variant that lifts this same message handling onto a real socket.

///|
/// Per-connection protocol state: whether `connection_init` has been seen, and
/// the operation ids already used (single-use, so a duplicate is a 4409).
priv struct GqlWsState {
  mut initialized : Bool
  used : Map[String, Unit]
}

///|
/// Build a `graphql-transport-ws` WebSocket handler for `schema` / `resolvers` /
/// `subscribers`. `root_value` and `context` are threaded to every operation the
/// way `execute` threads them. Negotiates the `graphql-transport-ws` subprotocol
/// when the client offers it.
pub fn graphql_ws_handler(
  schema : Schema,
  resolvers : Resolvers,
  subscribers : Subscribers,
  root_value? : Json = Json::null(),
  context? : Json = Json::null(),
) -> @moonasgi.WebSocketHandler {
  let state : GqlWsState = { initialized: false, used: Map([]), }
  @moonasgi.WebSocketHandler::new(
    on_connect=fn(scope) {
      if scope.subprotocols.contains("graphql-transport-ws") {
        @moonasgi.Accept(subprotocol=Some("graphql-transport-ws"), headers=[])
      } else {
        @moonasgi.Accept(subprotocol=None, headers=[])
      }
    },
    on_receive=fn(msg) {
      match msg {
        @moonasgi.Text(t) =>
          handle_gql_ws_text(
            state, schema, resolvers, subscribers, root_value, context, t,
          )
        @moonasgi.Binary(_) =>
          [@moonasgi.Close(code=4400, reason="binary frames are not allowed")]
      }
    },
  )
}

///|
/// A server-to-client message `{ id?, type, payload? }` as a JSON string.
fn gql_ws_message(type_ : String, id : String?, payload : Json?) -> String {
  let entries : Array[(String, Json)] = []
  match id {
    Some(i) => entries.push(("id", i.to_json()))
    None => ()
  }
  entries.push(("type", type_.to_json()))
  match payload {
    Some(p) => entries.push(("payload", p))
    None => ()
  }
  jobj(entries).stringify()
}

///|
/// Serialise a request error list as the `error` message's payload — a JSON array
/// of GraphQL error objects.
fn gql_ws_errors_json(errors : Array[GqlError]) -> Json {
  let arr : Array[Json] = []
  for e in errors {
    arr.push(e.to_json())
  }
  arr.to_json()
}

///|
/// Handle one text frame, returning the frames to send back. Parses the control
/// message and dispatches on its `type`.
fn handle_gql_ws_text(
  state : GqlWsState,
  schema : Schema,
  resolvers : Resolvers,
  subscribers : Subscribers,
  root_value : Json,
  context : Json,
  text : String,
) -> Array[@moonasgi.WsSend] {
  let json = @json.parse(text) catch {
    _ => return [@moonasgi.Close(code=4400, reason="invalid JSON")]
  }
  let obj = match json {
    Object(m) => m
    _ => return [@moonasgi.Close(code=4400, reason="message must be an object")]
  }
  let mtype = match obj.get("type") {
    Some(String(s)) => s
    _ => return [@moonasgi.Close(code=4400, reason="message is missing 'type'")]
  }
  match mtype {
    "connection_init" =>
      if state.initialized {
        [@moonasgi.Close(code=4429, reason="Too many initialisation requests")]
      } else {
        state.initialized = true
        [@moonasgi.SendText(gql_ws_message("connection_ack", None, None))]
      }
    "ping" =>
      [@moonasgi.SendText(gql_ws_message("pong", None, obj.get("payload")))]
    "pong" => []
    // The client wants to stop an operation. Finite pull sources have already
    // completed, so there is nothing to cancel — accept it.
    "complete" => []
    "subscribe" =>
      handle_subscribe(
        state, schema, resolvers, subscribers, root_value, context, obj,
      )
    _ => [@moonasgi.Close(code=4400, reason="invalid message type: " + mtype)]
  }
}

///|
/// Handle a `subscribe` message: authorise, claim the id, run the operation, and
/// map the outcome to `next`* + `complete` (success) or a single `error`.
fn handle_subscribe(
  state : GqlWsState,
  schema : Schema,
  resolvers : Resolvers,
  subscribers : Subscribers,
  root_value : Json,
  context : Json,
  obj : Map[String, Json],
) -> Array[@moonasgi.WsSend] {
  if not(state.initialized) {
    return [@moonasgi.Close(code=4401, reason="Unauthorized")]
  }
  let id = match obj.get("id") {
    Some(String(i)) => i
    _ =>
      return [@moonasgi.Close(code=4400, reason="subscribe requires an 'id'")]
  }
  if state.used.get(id) is Some(_) {
    return [
      @moonasgi.Close(
        code=4409,
        reason="Subscriber for " + id + " already exists",
      ),
    ]
  }
  state.used[id] = ()
  let payload = match obj.get("payload") {
    Some(Object(p)) => p
    _ =>
      return [
        @moonasgi.SendText(err_message(id, "subscribe is missing 'payload'")),
      ]
  }
  let query = match payload.get("query") {
    Some(String(q)) => q
    _ =>
      return [
        @moonasgi.SendText(
          err_message(id, "subscribe payload is missing 'query'"),
        ),
      ]
  }
  let variables : Map[String, Json] = match payload.get("variables") {
    Some(Object(v)) => v
    _ => Map([])
  }
  let op_name : String? = match payload.get("operationName") {
    Some(String(n)) => Some(n)
    _ => None
  }
  match operation_type_of(schema, query, op_name) {
    Err(errs) =>
      [
        @moonasgi.SendText(
          gql_ws_message("error", Some(id), Some(gql_ws_errors_json(errs))),
        ),
      ]
    Ok(Subscription) =>
      match
        create_source_event_stream(
          schema,
          resolvers,
          subscribers,
          query,
          variables~,
          operation_name=op_name,
          root_value~,
          context~,
        ) {
        RequestError(errs) =>
          [
            @moonasgi.SendText(
              gql_ws_message("error", Some(id), Some(gql_ws_errors_json(errs))),
            ),
          ]
        EventStream(payloads) => {
          let sends : Array[@moonasgi.WsSend] = []
          for p in payloads {
            sends.push(
              @moonasgi.SendText(gql_ws_message("next", Some(id), Some(p))),
            )
          }
          sends.push(
            @moonasgi.SendText(gql_ws_message("complete", Some(id), None)),
          )
          sends
        }
      }
    Ok(_) => {
      // A query or mutation over the subscribe transport: a single execution
      // result, then complete.
      let result = execute(
        schema,
        resolvers,
        query,
        variables~,
        operation_name=op_name,
        root_value~,
        context~,
      )
      [
        @moonasgi.SendText(gql_ws_message("next", Some(id), Some(result))),
        @moonasgi.SendText(gql_ws_message("complete", Some(id), None)),
      ]
    }
  }
}

///|
/// Build an `error` message carrying a single message string.
fn err_message(id : String, message : String) -> String {
  gql_ws_message(
    "error",
    Some(id),
    Some(gql_ws_errors_json([GqlError::msg(message)])),
  )
}

///|
/// Parse, validate, and select `query`'s operation, returning its type or the
/// request errors that stop it from starting. The peek that routes a `subscribe`
/// to the subscription stream or to `execute` (query/mutation), and turns a
/// parse/validation failure into an `error` message rather than a `next`.
fn operation_type_of(
  schema : Schema,
  query : String,
  operation_name : String?,
) -> Result[OperationType, Array[GqlError]] {
  let doc = parse(query) catch {
    GqlSyntaxError(m, line, col) =>
      return Err([
        { message: m, path: [], locations: [(line, col)], extensions: Map([]), },
      ])
  }
  let verrors = validate(schema, doc)
  if verrors.length() > 0 {
    return Err(verrors)
  }
  match select_operation(schema, doc, operation_name) {
    Ok(p) => Ok(p.operation.operation)
    Err(e) => Err([e])
  }
}
