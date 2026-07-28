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

Still feature-by-feature ahead: custom scalars and unions, a GraphiQL endpoint over the moonasgi SEAM (served by `mooncat`), DataLoader batching, and subscriptions.

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

## License

Apache-2.0.
