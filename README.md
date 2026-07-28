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

The code-first schema and SDL are here, now with **field arguments** (`field_args`), **input object types** (`Schema::input`), **enum types** (`Schema::enum_`), and **interfaces** (`Schema::interface` + object `implements`). Next, feature-by-feature: unions; a GraphQL query parser and validator; an executor with resolvers over the moonasgi SEAM (served by `mooncat`); introspection and a GraphiQL endpoint; then subscriptions and dataloaders.

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
