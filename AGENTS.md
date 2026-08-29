`moongql` is a GraphQL server for MoonBit — schema, parser, validation, execution, introspection, subscriptions, and federation. It follows strawberry-graphql in shape and the GraphQL spec in behaviour.

# Working here

- `moon fmt` before anything else. CI runs `moon fmt && git diff --exit-code`, so an unformatted file fails the build on its own.
- `moon check --target all --deny-warn` is the gate. Warnings are errors, and all four backends (wasm, wasm-gc, js, native) must pass.
- `moon test --target all` runs the suite everywhere; there are no target-specific tests.
- `moon info` regenerates `pkg.generated.mbti`. If that file does not change, your edit is not visible to anyone depending on this package, which usually means the refactor was safe. If it does change, read the diff before committing — that is the public interface moving.
- CI installs the latest moon on every run, so a toolchain that is behind will disagree with it. Upgrade locally rather than pinning.

# Layout

`lexer.mbt` and `parser.mbt` turn a document into the `ast.mbt` types; `validate.mbt` and `validate_rules.mbt` check it against the schema in `schema.mbt`; `execute.mbt` runs it. Around that: `introspection.mbt`, `directives.mbt`, `subscribe.mbt`, `gqlws.mbt` (the graphql-ws protocol), `federation.mbt`, `dataloader.mbt`, and `server.mbt` for the HTTP endpoint. Tests sit beside their subject as `*_wbtest.mbt`; `examples/NN-topic/` are runnable one-file demos.

# Things worth knowing

- The parser is recursive descent, by choice. GraphQL's grammar is close to LL(1) and the reference implementation is hand-written for the same reason: error messages. `token_desc` and `Parser::err` exist to say "expected X, found Y", which a generated parser gives up. Do not replace it with a parser generator.
- Validation rules cite their spec section in a comment (`§5.5.1.1` and so on). Keep that when adding a rule — it is how the coverage gets audited against the spec.
- The AST carries no source positions yet, so `locations` in an error response is empty. Adding them touches the lexer, the parser, and every rule that reports.
- Interfaces and unions resolve through a `__typename` carried in the resolved value. There is no separate type-resolver hook, so a resolver returning an abstract type must include it.
