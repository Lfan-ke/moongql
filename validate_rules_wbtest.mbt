///|
/// A small schema for exercising the document-level validation rules.
fn rules_schema() -> Schema {
  let s = Schema::new()
  let q = s.object("Query")
  q.field_args("user", [("id", NonNull(Scalar("ID")))], Named("User"))
  q.field("hello", NonNull(Scalar("String")))
  let u = s.object("User")
  u.field("id", NonNull(Scalar("ID")))
  u.field("name", NonNull(Scalar("String")))
  s
}

///|
/// The validation errors for `query` against `s`, joined one per line (so a test
/// can assert a message is present, or that the string is empty for a valid query).
fn verr_text(s : Schema, query : String) -> String {
  let doc = parse(query) catch { GqlSyntaxError(m, _, _) => return m }
  let sb = StringBuilder::new()
  for e in validate(s, doc) {
    sb.write_string(e.message)
    sb.write_char('\n')
  }
  sb.to_string()
}

///|
/// §5.2.1.1: two operations may not share a name.
test "operation name uniqueness" {
  let s = rules_schema()
  assert_eq(
    verr_text(
      s,
      (
        #|query A { hello }
        #|query A { hello }
      ),
    ).contains("There can be only one operation named 'A'"),
    true,
  )
}

///|
/// §5.2.2.1: an anonymous operation must stand alone.
test "lone anonymous operation" {
  let s = rules_schema()
  assert_eq(
    verr_text(
      s,
      (
        #|{ hello }
        #|query B { hello }
      ),
    ).contains("anonymous operation must be the only defined operation"),
    true,
  )
}

///|
/// §5.4.2: a field's arguments must have unique names.
test "argument uniqueness" {
  let s = rules_schema()
  assert_eq(
    verr_text(
      s,
      (
        #|{ user(id: "1", id: "2") { name } }
      ),
    ).contains("Duplicate argument 'id' on 'user'"),
    true,
  )
}

///|
/// §5.5.1.1: two fragments may not share a name.
test "fragment name uniqueness" {
  let s = rules_schema()
  assert_eq(
    verr_text(
      s,
      (
        #|{ user(id: "1") { ...F } }
        #|fragment F on User { name }
        #|fragment F on User { id }
      ),
    ).contains("There can be only one fragment named 'F'"),
    true,
  )
}

///|
/// §5.5.1.4: a defined fragment must be used.
test "no unused fragments" {
  let s = rules_schema()
  assert_eq(
    verr_text(
      s,
      (
        #|{ hello }
        #|fragment Unused on User { name }
      ),
    ).contains("Fragment 'Unused' is never used"),
    true,
  )
}

///|
/// §5.5.2.2: fragment spreads must not form a cycle.
test "no fragment spread cycles" {
  let s = rules_schema()
  let errs = verr_text(
    s,
    (
      #|{ user(id: "1") { ...A } }
      #|fragment A on User { name ...B }
      #|fragment B on User { id ...A }
    ),
  )
  assert_eq(errs.contains("Fragment 'A' spreads itself (cycle)"), true)
  assert_eq(errs.contains("Fragment 'B' spreads itself (cycle)"), true)
}

///|
/// §5.8.1: a variable may be defined only once in an operation.
test "variable uniqueness" {
  let s = rules_schema()
  assert_eq(
    verr_text(
      s,
      (
        #|query ($x: ID!, $x: ID!) { user(id: $x) { name } }
      ),
    ).contains("Duplicate variable '$x'"),
    true,
  )
}

///|
/// §5.8.4: every defined variable must be used.
test "no unused variables" {
  let s = rules_schema()
  assert_eq(
    verr_text(
      s,
      (
        #|query ($x: ID!) { hello }
      ),
    ).contains("Variable '$x' is never used"),
    true,
  )
}

///|
/// §5.8.3: a referenced variable must be defined.
test "undefined variable use" {
  let s = rules_schema()
  assert_eq(
    verr_text(
      s,
      (
        #|query { user(id: $y) { name } }
      ),
    ).contains("Variable '$y' is not defined"),
    true,
  )
}

///|
/// A query using variables, a fragment and a directive, all correctly, raises no
/// validation errors — the rules do not fire on valid documents.
test "a valid document passes every rule" {
  let s = rules_schema()
  assert_eq(
    verr_text(
      s,
      (
        #|query GetUser($id: ID!, $show: Boolean!) {
        #|  user(id: $id) { ...UserFields }
        #|}
        #|fragment UserFields on User { id name @include(if: $show) }
      ),
    ),
    "",
  )
}
