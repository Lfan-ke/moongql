///|
/// Named fragments and inline fragments. `fragment UserFields on User { .. }` is
/// spread with `...UserFields`, and an inline `... on User { age }` adds more fields
/// in place — both contribute to one merged selection on the resolved object.
///
///     moon run examples/04-fragments
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
  u.field("age", @moongql.Scalar("Int"))
  let r = @moongql.Resolvers::new()
  r.field("Query", "user", fn(_info) {
    { "id": "1", "name": "qwe", "age": 233 }
  })
  let query =
    #|{
    #|  user(id: "1") {
    #|    ...UserFields
    #|    ... on User { age }
    #|  }
    #|}
    #|
    #|fragment UserFields on User { id name }
  println(@moongql.execute(s, r, query).stringify())
}
