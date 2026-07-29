///|
/// A client control frame `{ type }` as a text message.
fn ctrl_frame(type_ : String) -> @moonasgi.WsMessage {
  @moonasgi.Text(jobj([("type", type_.to_json())]).stringify())
}

///|
/// A `subscribe` frame `{ id, type, payload: { query } }` as a text message.
fn subscribe_frame(id : String, query : String) -> @moonasgi.WsMessage {
  let payload = jobj([("query", query.to_json())])
  @moonasgi.Text(
    jobj([
      ("id", id.to_json()),
      ("type", "subscribe".to_json()),
      ("payload", payload),
    ]).stringify(),
  )
}

///|
/// The text bodies of the `SendText` frames in a handler's reply, in order.
fn sent_texts(sends : Array[@moonasgi.WsSend]) -> Array[String] {
  let out : Array[String] = []
  for s in sends {
    match s {
      @moonasgi.SendText(t) => out.push(t)
      _ => ()
    }
  }
  out
}

///|
/// The close code in a handler's reply, or -1 if it did not close.
fn close_code(sends : Array[@moonasgi.WsSend]) -> Int {
  for s in sends {
    if s is @moonasgi.Close(code~, ..) {
      return code
    }
  }
  -1
}

///|
test "graphql-transport-ws acks init, then streams next* and complete" {
  let h = graphql_ws_handler(sub_schema(), Resolvers::new(), sub_subscribers())
  let ack = sent_texts((h.on_receive)(ctrl_frame("connection_init")))
  assert_eq(ack.length(), 1)
  assert_eq(ack[0], "{\"type\":\"connection_ack\"}")
  let out = sent_texts(
    (h.on_receive)(subscribe_frame("1", "subscription { ticks }")),
  )
  assert_eq(out.length(), 3)
  assert_eq(
    out[0],
    "{\"id\":\"1\",\"type\":\"next\",\"payload\":{\"data\":{\"ticks\":1}}}",
  )
  assert_eq(
    out[1],
    "{\"id\":\"1\",\"type\":\"next\",\"payload\":{\"data\":{\"ticks\":2}}}",
  )
  assert_eq(out[2], "{\"id\":\"1\",\"type\":\"complete\"}")
}

///|
test "graphql-transport-ws refuses a subscribe before connection_init (4401)" {
  let h = graphql_ws_handler(sub_schema(), Resolvers::new(), sub_subscribers())
  assert_eq(
    close_code((h.on_receive)(subscribe_frame("1", "subscription { ticks }"))),
    4401,
  )
}

///|
test "graphql-transport-ws refuses a second connection_init (4429)" {
  let h = graphql_ws_handler(sub_schema(), Resolvers::new(), sub_subscribers())
  (h.on_receive)(ctrl_frame("connection_init")) |> ignore
  assert_eq(close_code((h.on_receive)(ctrl_frame("connection_init"))), 4429)
}

///|
test "graphql-transport-ws refuses a reused operation id (4409)" {
  let h = graphql_ws_handler(sub_schema(), Resolvers::new(), sub_subscribers())
  (h.on_receive)(ctrl_frame("connection_init")) |> ignore
  (h.on_receive)(subscribe_frame("1", "subscription { ticks }")) |> ignore
  assert_eq(
    close_code((h.on_receive)(subscribe_frame("1", "subscription { ticks }"))),
    4409,
  )
}

///|
test "graphql-transport-ws answers ping with pong, echoing the payload" {
  let h = graphql_ws_handler(sub_schema(), Resolvers::new(), sub_subscribers())
  assert_eq(
    sent_texts((h.on_receive)(ctrl_frame("ping")))[0],
    "{\"type\":\"pong\"}",
  )
  let ping = @moonasgi.Text(
    jobj([("type", "ping".to_json()), ("payload", jobj([("n", (1).to_json())]))]).stringify(),
  )
  assert_eq(
    sent_texts((h.on_receive)(ping))[0],
    "{\"type\":\"pong\",\"payload\":{\"n\":1}}",
  )
}

///|
test "graphql-transport-ws closes on a binary frame (4400)" {
  let h = graphql_ws_handler(sub_schema(), Resolvers::new(), sub_subscribers())
  assert_eq(close_code((h.on_receive)(@moonasgi.Binary(b"\x00"))), 4400)
}

///|
test "graphql-transport-ws sends an error message for a request that cannot start" {
  let h = graphql_ws_handler(sub_schema(), Resolvers::new(), sub_subscribers())
  (h.on_receive)(ctrl_frame("connection_init")) |> ignore
  // A parse failure is a request error -> a single `error` message, not a `next`.
  let out = sent_texts((h.on_receive)(subscribe_frame("9", "{")))
  assert_eq(out.length(), 1)
  assert_eq(out[0].contains("\"type\":\"error\""), true)
  assert_eq(out[0].contains("\"id\":\"9\""), true)
}

///|
test "graphql-transport-ws runs a query over the subscribe transport (single next + complete)" {
  let r = Resolvers::new()
  r.field("Query", "ok", _info => "yes".to_json())
  let h = graphql_ws_handler(sub_schema(), r, sub_subscribers())
  (h.on_receive)(ctrl_frame("connection_init")) |> ignore
  let out = sent_texts((h.on_receive)(subscribe_frame("q1", "{ ok }")))
  assert_eq(out.length(), 2)
  assert_eq(
    out[0],
    "{\"id\":\"q1\",\"type\":\"next\",\"payload\":{\"data\":{\"ok\":\"yes\"}}}",
  )
  assert_eq(out[1], "{\"id\":\"q1\",\"type\":\"complete\"}")
}

///|
test "graphql-transport-ws negotiates the subprotocol on connect" {
  let h = graphql_ws_handler(sub_schema(), Resolvers::new(), sub_subscribers())
  let offered = @moonasgi.WebSocketScope::new(path="/graphql", subprotocols=[
    "graphql-transport-ws",
  ])
  let chosen = match (h.on_connect)(offered) {
    @moonasgi.Accept(subprotocol~, ..) => subprotocol
    _ => None
  }
  assert_eq(chosen, Some("graphql-transport-ws"))
  let bare = @moonasgi.WebSocketScope::new(path="/graphql")
  let none_chosen = match (h.on_connect)(bare) {
    @moonasgi.Accept(subprotocol~, ..) => subprotocol
    _ => Some("unexpected")
  }
  assert_eq(none_chosen, None)
}
