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
- Every AST node an error can point at carries a `Pos` the parser fills from the token it started on, and `GqlError.locations` is what reaches the response. A new validation rule reports with `Validator::err_at`; plain `err` is for the handful of errors about the document as a whole, which have no node to name.
- There is no shutdown API here, deliberately. A subscription is drained at `subscribe` time and completed in the same batch, so no operation is ever live between two client messages and nothing outlives a request. A client's `complete` therefore has nothing to cancel; it releases the operation's id. Streaming a subscription over time — a real event source rather than a materialised list — is what would create something to drain, and that change comes first. `GqlWs::claim` / `release` are the seam it would use: they are what keeps an id claimed while a live source is still sending.
- `GqlWs` holds the protocol's timers as state and nothing more, because the package has neither a runtime nor a clock. A server calls `tick` with a monotonic millisecond reading and sends what comes back; without that there is no connection-init timeout and no keep-alive ping.
- Interfaces and unions resolve through a `__typename` carried in the resolved value. There is no separate type-resolver hook, so a resolver returning an abstract type must include it.
