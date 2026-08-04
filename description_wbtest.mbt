///|
test "field description surfaces in introspection __Field.description" {
  let schema = Schema::new(query="Query")
  let query = schema.object("Query")
  query.field("hero", Scalar("String"), description="the main hero")
  query.field("plain", Scalar("String"))
  let q =
    #|{ __type(name: "Query") { fields { name description } } }
  let res = execute(schema, Resolvers::new(), q)
  guard res is Object(m) else { fail("response should be an object") }
  guard m.get("data") is Some(Object(data)) else { fail("data") }
  guard data.get("__type") is Some(Object(t)) else { fail("__type") }
  guard t.get("fields") is Some(Array(fields)) else { fail("fields") }
  let mut hero_desc : Json? = None
  let mut plain_desc : Json? = None
  for fj in fields {
    match fj {
      Object(fm) =>
        if fm.get("name") == Some("hero".to_json()) {
          hero_desc = fm.get("description")
        } else if fm.get("name") == Some("plain".to_json()) {
          plain_desc = fm.get("description")
        }
      _ => ()
    }
  }
  assert_eq(hero_desc, Some("the main hero".to_json()))
  // A field with no description reports `null`, per the introspection schema.
  assert_eq(plain_desc, Some(Json::null()))
}
