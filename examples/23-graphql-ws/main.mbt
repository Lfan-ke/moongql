///|
/// A client control frame `{ type }` as a text message.
fn ctrl_frame(type_ : String) -> @moonasgi.WsMessage {
  let m : Json = { "type": type_.to_json() }
  @moonasgi.Text(m.stringify())
}

///|
/// A `subscribe` frame `{ id, type, payload: { query } }` as a text message.
fn subscribe_frame(id : String, query : String) -> @moonasgi.WsMessage {
  let payload : Json = { "query": query.to_json() }
  let m : Json = { "id": id.to_json(), "type": "subscribe", "payload": payload }
  @moonasgi.Text(m.stringify())
}

///|
/// The text bodies of the `SendText` frames a handler emits, in order.
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
/// Subscriptions over the `graphql-transport-ws` protocol. `graphql_ws_handler`
/// returns a WebSocket handler whose `on_receive` maps one client frame to the
/// frames sent back — the synchronous seam under the async socket. A
/// `connection_init` is answered with `connection_ack`; a `subscribe` streams one
/// `next` per source event and closes with `complete`.
///
///     moon run examples/23-graphql-ws
#coverage.skip
fn main {
  let s = @moongql.Schema::new()
  let q = s.object("Query")
  q.field("ok", @moongql.NonNull(@moongql.Scalar("String")))
  s.set_subscription("Subscription")
  let sub = s.object("Subscription")
  sub.field("ticks", @moongql.NonNull(@moongql.Scalar("Int")))
  let subs = @moongql.Subscribers::new()
  subs.field("Subscription", "ticks", _info => [(1).to_json(), (2).to_json()])
  let h = @moongql.graphql_ws_handler(s, @moongql.Resolvers::new(), subs)
  for t in sent_texts((h.on_receive)(ctrl_frame("connection_init"))) {
    println("ack: " + t)
  }
  for
    t in sent_texts(
      (h.on_receive)(subscribe_frame("1", "subscription { ticks }")),
    ) {
    println("frame: " + t)
  }
}
