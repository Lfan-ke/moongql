///|
/// Encode a GraphQL-over-HTTP POST body as `{ query, variables }` JSON.
fn request_body(query : String, variables : Json) -> Bytes {
  let obj : Json = { "query": query.to_json(), "variables": variables }
  @utf8.encode(obj.stringify())
}

///|
/// The GraphQL-over-HTTP transport. `graphql_handler` turns a schema into a
/// moonasgi request handler; moonasgi's `TestClient` drives it over the synchronous
/// seam (no socket). A POST runs the query and returns `200 application/json` with
/// the `{ data }` body, request variables bind, and a GET serves the GraphiQL IDE.
/// `graphiql_html` renders that page pointed at any endpoint path.
///
///     moon run examples/22-http-server
#coverage.skip
fn main {
  let s = @moongql.Schema::new()
  let q = s.object("Query")
  q.field_args(
    "user",
    [("id", @moongql.NonNull(@moongql.Scalar("ID")))],
    @moongql.Named("User"),
  )
  let u = s.object("User")
  u.field("id", @moongql.NonNull(@moongql.Scalar("ID")))
  u.field("name", @moongql.NonNull(@moongql.Scalar("String")))
  let r = @moongql.Resolvers::new()
  r.field("Query", "user", info => {
    match info.arg("id") {
      String("1") => { "id": "1", "name": "lfanke" }
      _ => Json::null()
    }
  })
  let client = @moonasgi.TestClient::new(@moongql.graphql_handler(s, r))
  let body = request_body("{ user(id: \"1\") { id name } }", Json::null())
  let resp = client.post("/graphql", body~)
  println("POST status: \{resp.status}")
  let ctype = match resp.header("content-type") {
    Some(h) => h
    None => "?"
  }
  println("content-type: " + ctype)
  println("body: " + resp.text())
  let vars : Json = { "uid": "1" }
  let body2 = request_body(
    "query ($uid: ID!) { user(id: $uid) { name } }", vars,
  )
  println("vars body: " + client.post("/graphql", body=body2).text())
  let page = client.get("/graphql")
  println("GET status: \{page.status}")
  println("serves GraphiQL: \{page.text().contains("<title>GraphiQL</title>")}")
  let standalone = @moongql.graphiql_html(endpoint="/api/graphql")
  println(
    "fetcher target present: \{standalone.contains("url: '/api/graphql'")}",
  )
}
