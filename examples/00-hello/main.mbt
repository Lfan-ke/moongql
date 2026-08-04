///|
/// Define a one-type schema, register a field resolver, run a query string and
/// print the `{ data }` JSON — the smallest end-to-end moongql pipeline.
///
///     moon run examples/00-hello
#coverage.skip
fn main {
  let schema = @moongql.Schema::new()
  let query = schema.object("Query")
  query.field("greeting", @moongql.NonNull(@moongql.Scalar("String")))
  query.field("luckyNumber", @moongql.NonNull(@moongql.Scalar("Int")))
  let resolvers = @moongql.Resolvers::new()
  resolvers.field("Query", "greeting", fn(_info) {
    "qwq from moongql".to_json()
  })
  resolvers.field("Query", "luckyNumber", fn(_info) { (233).to_json() })
  let res = @moongql.execute(schema, resolvers, "{ greeting luckyNumber }")
  println(res.stringify())
}
