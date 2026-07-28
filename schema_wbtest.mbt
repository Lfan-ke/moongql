///|
fn contains(haystack : String, needle : String) -> Bool {
  let hn = haystack.length()
  let nn = needle.length()
  if nn == 0 {
    return true
  }
  for i = 0; i + nn <= hn; i = i + 1 {
    let mut ok = true
    for j = 0; j < nn; j = j + 1 {
      if haystack[i + j] != needle[j] {
        ok = false
        break
      }
    }
    if ok {
      return true
    }
  }
  false
}

///|
test "code-first schema renders to SDL" {
  let s = Schema::new()
  let q = s.object("Query")
  q.field("hello", NonNull(Scalar("String")))
  let u = s.object("User")
  u.field("id", NonNull(Scalar("ID")))
  u.field("name", NonNull(Scalar("String")))
  u.field("tags", ListOf(NonNull(Scalar("String"))))
  q.field("user", Named("User"))
  let sdl = s.to_sdl()
  assert_eq(contains(sdl, "schema {\n  query: Query\n}"), true)
  assert_eq(contains(sdl, "type Query {"), true)
  assert_eq(contains(sdl, "hello: String!"), true)
  assert_eq(contains(sdl, "user: User"), true)
  assert_eq(contains(sdl, "type User {"), true)
  assert_eq(contains(sdl, "id: ID!"), true)
  assert_eq(contains(sdl, "tags: [String!]"), true)
}

///|
test "custom root query name" {
  let s = Schema::new(query="RootQuery")
  s.object("RootQuery").field("ping", NonNull(Scalar("Boolean")))
  assert_eq(contains(s.to_sdl(), "query: RootQuery"), true)
  assert_eq(contains(s.to_sdl(), "ping: Boolean!"), true)
}
