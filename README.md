<div align="center">

# moongql

**A code-first GraphQL library for MoonBit — `← strawberry-graphql`.**

[![Check and Test](https://github.com/Lfan-ke/moongql/actions/workflows/ci.yml/badge.svg)](https://github.com/Lfan-ke/moongql/actions/workflows/ci.yml)
[![License](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](./LICENSE)
[![mooncakes](https://img.shields.io/badge/mooncakes-Lfan--ke%2Fmoongql-brightgreen)](https://mooncakes.io/docs/Lfan-ke/moongql)

</div>

`moongql` defines a GraphQL schema **in code** — object types and fields — the way `strawberry-graphql` does for Python, and emits the schema SDL. `v0` ships the code-first schema and SDL printer; it's pure logic with no runtime dependencies, so it runs on every backend.

## Quickstart

```moonbit
let s = @moongql.Schema::new()

let q = s.object("Query")
q.field("hello", @moongql.NonNull(@moongql.Scalar("String")))
q.field("user", @moongql.Named("User"))

let u = s.object("User")
u.field("id", @moongql.NonNull(@moongql.Scalar("ID")))
u.field("name", @moongql.NonNull(@moongql.Scalar("String")))
u.field("tags", @moongql.ListOf(@moongql.NonNull(@moongql.Scalar("String"))))

let sdl = s.to_sdl()
```

produces:

```graphql
schema {
  query: Query
}

type Query {
  hello: String!
  user: User
}

type User {
  id: ID!
  name: String!
  tags: [String!]
}
```

Verified across all backends (`wasm`, `wasm-gc`, `js`, `native`) in CI, 0 warnings under `--deny-warn`.

## Roadmap (transliterating strawberry)

The code-first schema and SDL are here, with **field arguments** (`field_args`), **input object types** (`Schema::input`), **enum types** (`Schema::enum_`), and **interfaces** (`Schema::interface` + object `implements`). The **query parser** now lands too — a hand-written lexer and a recursive-descent parser that turn a query string into a `Document` AST:

```moonbit
let doc = @moongql.parse(
  "query ($id: ID!) { user(id: $id) { name ...fields @skip(if: false) } }",
)
// doc.definitions[0] is an OperationDefinition; doc.to_query() prints it back.
```

It covers operations (`query`/`mutation`/`subscription` and the `{ ... }` shorthand), selection sets, fields with aliases/arguments/directives, variable definitions with default values, named and inline fragments, `@skip`/`@include` directives, and every input value (variables, ints, floats, strings, block strings, booleans, null, enums, lists, objects) — enough to parse the full GraphQL introspection query.

## Executing a query

`moongql` now **runs** queries. `execute` parses, validates against the schema, then walks the document with a **resolver map** — `(ResolveInfo) -> Json` functions keyed by `"Type.field"` — returning the `{ data, errors }` response as JSON. It supports variables (with defaults), aliases, named and inline fragments, `@skip`/`@include`, nested selection, list and object results, non-null error propagation, and full introspection (`__schema` / `__type` / `__typename`).

```moonbit
let s = @moongql.Schema::new()
let q = s.object("Query")
q.field_args("user", [("id", @moongql.NonNull(@moongql.Scalar("ID")))],
  @moongql.Named("User"))
let u = s.object("User")
u.field("id", @moongql.NonNull(@moongql.Scalar("ID")))
u.field("name", @moongql.NonNull(@moongql.Scalar("String")))

let r = @moongql.Resolvers::new()
r.field("Query", "user", fn(info) {
  match info.arg("id") {
    String("1") => { "id": "1", "name": "Alice" }
    _ => Json::null()
  }
})
// User.id / User.name fall back to the default resolver (read off the parent).

let vars : Map[String, Json] = { "uid": "1" }
let res = @moongql.execute(s, r,
  "query ($uid: ID!) { hero: user(id: $uid) { id name } }", variables=vars)
// res.stringify() == {"data":{"hero":{"id":"1","name":"Alice"}}}
```

### Design: faithful equivalences to strawberry

MoonBit has no runtime reflection, so where strawberry discovers resolvers and schema from Python classes, `moongql` uses **explicit** values: resolvers are functions registered by `"Type.field"` (like Rust/Go GraphQL servers), and a field's declared return type drives leaf-vs-composite completion exactly as `graphql-core`'s `complete_value` does. Fields with no registered resolver read their value off the parent JSON object — the equivalent of `graphql-core`'s `default_field_resolver`.

Union types, custom scalars, subscriptions, a DataLoader, a GraphiQL HTTP endpoint, and Apollo Federation all land too (below).

```moonbit
let s = @moongql.Schema::new()

let node = s.interface("Node")
node.field("id", @moongql.NonNull(@moongql.Scalar("ID")))

let q = s.object("Query")
q.field_args(
  "user",
  [("id", @moongql.NonNull(@moongql.Scalar("ID")))],
  @moongql.Named("User"),
)

let u = s.object("User")
u.implements("Node")
u.field("id", @moongql.NonNull(@moongql.Scalar("ID")))

let inp = s.input("UserFilter")
inp.field("name", @moongql.Scalar("String"))

s.enum_("Role", ["ADMIN", "USER"])
```

emits `user(id: ID!): User`, `type User implements Node { .. }`, `input UserFilter { .. }`, and `enum Role { ADMIN USER }`.

## Unions and custom scalars

Declare a union with `Schema::union` and select into it through inline fragments; each value is discriminated by its `__typename`:

```moonbit
s.union("SearchResult", ["Book", "Author"])
// { search { __typename ... on Book { title } ... on Author { name } } }
```

A custom scalar carries its own `serialize` (output) and `parse_value` (input) hooks, the same two coercions strawberry's `Scalar` defines. Input arguments and variables run through `parse_value` before a resolver sees them; resolver results run through `serialize`:

```moonbit
s.scalar("DateTime",
  serialize=fn(j) { j },      // value -> output JSON
  parse_value=fn(j) { j })    // input JSON -> value
```

Both show up in SDL (`union SearchResult = Book | Author`, `scalar DateTime`) and in introspection (`kind: UNION` with `possibleTypes`, `kind: SCALAR`).

## Subscriptions

A subscription has one root field backed by a source stream. `execute_subscription` returns the ordered payloads a client would receive, one `{ data, errors }` per event. The stream is a pull source — a resolver returning `Array[Json]` — so the whole pipeline runs on every backend; the async native variant over a WebSocket wraps the same per-event core.

```moonbit
let subs = @moongql.Subscribers::new()
subs.field("Subscription", "messageAdded", fn(info) {
  // one Json payload per event, in delivery order
  [msg1, msg2, msg3]
})

let payloads = @moongql.execute_subscription(schema, resolvers, subs,
  "subscription { messageAdded(channel: \"general\") { id body } }")
// payloads[0].stringify() == {"data":{"messageAdded":{"id":"1","body":"hello"}}}
```

The single-root-field rule (spec §5.2.3.1) is enforced, and an introspection field can't be a subscription root.

## DataLoader

`DataLoader` is the batch-and-cache tool for the N+1 problem. Keys requested during a resolution pass are queued and deduped; one `dispatch` runs the batch function once over the distinct keys:

```moonbit
let loader : @moongql.DataLoader[Int, String] = @moongql.DataLoader::new(
  fn(ids) { load_authors(ids) },  // called once per pass
  fn(id) { id.to_string() },      // cache-key function
)
loader.load(1); loader.load(2); loader.load(1)  // three requests, two keys
loader.dispatch()                               // one batch call for {1, 2}
loader.get(1)                                   // Some("author#1")
```

`prime`, `clear`, `clear_all`, `load_many` and `load_now` round out the API. Where Facebook's DataLoader coalesces within an event-loop tick, this drains the queue explicitly so it stays testable without a runtime.

## HTTP endpoint

`graphql_handler` wires a schema and its resolvers onto the [moonasgi](https://mooncakes.io/docs/Lfan-ke/moonasgi) seam, so moongql serves over `mooncat` (or any server that binds the ASGI callable). A `GET` returns the GraphiQL IDE; a `POST` reads a `{ query, variables, operationName }` body, runs it, and replies with the `{ data, errors }` JSON:

```moonbit
let handler = @moongql.graphql_handler(schema, resolvers)      // path defaults to /graphql
let app = @moongql.graphql_app(schema, resolvers)              // the same, lifted onto an AsgiApp
```

`graphql_app` is what a server mounts. The request/response logic is shared with `graphql_handler`, which moonasgi's `TestClient` drives without a socket — so the endpoint is tested on every backend:

```moonbit
let client = @moonasgi.TestClient::new(@moongql.graphql_handler(schema, resolvers))
let body = @utf8.encode(
  "{\"query\":\"{ user(id: \\\"1\\\") { name } }\"}",
)
let resp = client.post("/graphql", body~)
// resp.status == 200, resp.text() == {"data":{"user":{"name":"Alice"}}}
```

## Apollo Federation

A subgraph exposes `_service { sdl }` (its SDL, annotated with the federation directives), the `_entities(representations:)` resolver that turns a `{ __typename, <key> }` reference back into a full object, and `@key` / `@extends` / `@external` markers. Register the entity types and their reference resolvers, then `apply` installs the machinery — the `_Service` type, the `_Any` scalar, the `_Entity` union, and the two root fields — so the ordinary executor answers a federated query:

```moonbit
let fed = @moongql.Federation::new()
fed.entity(name="User", key="id", resolve=(rep, _ctx) => {
  let id = match rep {
    Object(m) => match m.get("id") { Some(String(s)) => s; _ => "" }
    _ => ""
  }
  { "id": id, "name": "User#" + id }.to_json()  // materialise from the key
})
fed.apply(schema, resolvers)

// { _service { sdl } } -> the subgraph SDL with `type User @key(fields: "id")`
// _entities(representations: [{ __typename: "User", id: "7" }]) -> the User object
```

An extended type declares `extends=true` and lists its `external` fields, which render as `extend type ... @key(...)` with `@external` on the borrowed fields — the shape a gateway composes.

## License

Apache-2.0.
