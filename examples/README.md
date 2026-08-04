# Examples

A tour of the public `@moongql` API. Each folder is a runnable `main` package
that builds a schema in code and runs a query against it.

```bash
moon run examples/00-hello
```

| # | Example | What it teaches | Key API |
| --- | --- | --- | --- |
| 00 | [`hello`](00-hello/) | Define a one-type schema, register a resolver, execute a query string and print the JSON result | `Schema::new`, `Schema::object`, `ObjectType::field`, `Resolvers::new`, `Resolvers::field`, `execute` |

`00-hello` declares a `Query` type with two scalar fields, backs each with a
resolver keyed by `"Type.field"`, then runs `{ greeting luckyNumber }` through
`execute` and prints the `{ data }` response:

```
{"data":{"greeting":"qwq from moongql","luckyNumber":233}}
```
