///|
test "resolver ResolverErrorExt carries extensions into the errors JSON" {
  let schema = Schema::new(query="Query")
  schema.object("Query").field("boom", Scalar("String"))
  let resolvers = Resolvers::new()
  resolvers.field("Query", "boom", _info => {
    raise ResolverErrorExt(
      "kaboom",
      Map([("code", "qwq".to_json()), ("status", (233).to_json())]),
    )
  })
  let res = execute(schema, resolvers, "{ boom }")
  guard res is Object(m) else { fail("response should be an object") }
  guard m.get("errors") is Some(Array(errs)) else { fail("errors array") }
  assert_eq(errs.length(), 1)
  guard errs[0] is Object(e0) else { fail("error should be an object") }
  assert_eq(e0.get("message"), Some("kaboom".to_json()))
  guard e0.get("extensions") is Some(Object(ext)) else {
    fail("extensions should be present")
  }
  assert_eq(ext.get("code"), Some("qwq".to_json()))
  assert_eq(ext.get("status"), Some((233).to_json()))
  // A plain ResolverError still omits `extensions` entirely.
  let r2 = Resolvers::new()
  r2.field("Query", "boom", _info => raise ResolverError("plain"))
  let res2 = execute(schema, r2, "{ boom }")
  guard res2 is Object(m2) else { fail("object") }
  guard m2.get("errors") is Some(Array(e2)) else { fail("errors2") }
  guard e2[0] is Object(err2) else { fail("error2") }
  assert_eq(err2.get("extensions"), None)
}
