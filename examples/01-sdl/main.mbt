///|
/// Declare every kind of type moongql supports — object, input, interface, enum,
/// union and custom scalar, with field arguments and `implements` — then print the
/// whole schema as GraphQL SDL with `to_sdl`. No execution here: this is the
/// code-first schema and the shape the printer emits.
///
///     moon run examples/01-sdl
#coverage.skip
fn main {
  let s = @moongql.Schema::new()
  let q = s.object("Query")
  q.field("me", @moongql.Named("User"))
  q.field_args(
    "search",
    [("filter", @moongql.Named("UserFilter"))],
    @moongql.NonNull(
      @moongql.ListOf(@moongql.NonNull(@moongql.Named("SearchResult"))),
    ),
  )
  let node = s.interface("Node")
  node.field("id", @moongql.NonNull(@moongql.Scalar("ID")))
  let user = s.object("User")
  user.implements("Node")
  user.field("id", @moongql.NonNull(@moongql.Scalar("ID")))
  user.field("name", @moongql.NonNull(@moongql.Scalar("String")))
  user.field("role", @moongql.Named("Role"))
  user.field("joined", @moongql.Named("DateTime"))
  let post = s.object("Post")
  post.field("title", @moongql.NonNull(@moongql.Scalar("String")))
  let filter = s.input("UserFilter")
  filter.field("name", @moongql.Scalar("String"))
  filter.field("role", @moongql.Named("Role"))
  s.enum_("Role", ["ADMIN", "USER", "GUEST"])
  s.union("SearchResult", ["User", "Post"])
  s.scalar("DateTime")
  println(s.to_sdl())
}
