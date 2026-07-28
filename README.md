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

The code-first schema and SDL are here. Next, feature-by-feature: field arguments and input types, enums / interfaces / unions; a GraphQL query parser and validator; an executor with resolvers over the moonasgi SEAM (served by `mooncat`); introspection and a GraphiQL endpoint; then subscriptions and dataloaders.

## License

Apache-2.0.
