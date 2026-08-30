///|
/// The response's own `extensions` entry (spec §7.1) — what the server wants to
/// say alongside the result — rides with `data`, and is left out when empty.
test "response extensions ride alongside data" {
  let schema = Schema::new(query="Query")
  schema.object("Query").field("ok", Scalar("String"))
  let resolvers = Resolvers::new()
  resolvers.field("Query", "ok", _info => "yes".to_json())
  let res = execute(
    schema,
    resolvers,
    "{ ok }",
    extensions=Map([("traceId", "qwq-233".to_json()), ("ms", (23).to_json())]),
  )
  assert_eq(
    res.stringify(),
    (
      #|{"data":{"ok":"yes"},"extensions":{"traceId":"qwq-233","ms":23}}
    ),
  )
  assert_eq(
    execute(schema, resolvers, "{ ok }").stringify(),
    (
      #|{"data":{"ok":"yes"}}
    ),
  )
}

///|
/// A request that never executes still carries the server's extensions, so a
/// trace id survives a rejected document.
test "response extensions ride with a request error too" {
  let schema = Schema::new(query="Query")
  schema.object("Query").field("ok", Scalar("String"))
  let res = execute(
    schema,
    Resolvers::new(),
    "{ nope }",
    extensions=Map([("traceId", "hhh-66666".to_json())]),
  )
  guard res is Object(m) else { fail("response should be an object") }
  assert_eq(m.get("data"), None)
  assert_eq(
    m.get("extensions"),
    Some(jobj([("traceId", "hhh-66666".to_json())])),
  )
}

///|
/// The response's own `extensions` entry, or `None` when it carries none.
fn response_extensions(res : Json) -> Json? {
  guard res is Object(m) else { return None }
  m.get("extensions")
}

///|
/// Every way a request can fail before it runs still carries the server's
/// extensions, so a trace id survives whichever gate stopped the request.
test "response extensions survive every request-level failure" {
  let schema = Schema::new(query="Query")
  schema.object("Query").field("ok", Scalar("String"))
  let r = Resolvers::new()
  let ext : Map[String, Json] = Map([("traceId", "orz-233".to_json())])
  let want = Some(jobj([("traceId", "orz-233".to_json())]))
  // A document that does not parse.
  assert_eq(
    response_extensions(execute(schema, r, "{ ok", extensions=ext)),
    want,
  )
  // A document whose operation cannot be chosen.
  assert_eq(
    response_extensions(
      execute(schema, r, "query A { ok } query B { ok }", extensions=ext),
    ),
    want,
  )
  // A required variable the request never supplied.
  assert_eq(
    response_extensions(
      execute(
        schema,
        r,
        "query Q($v: Boolean!) { ok @skip(if: $v) }",
        extensions=ext,
      ),
    ),
    want,
  )
}

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
