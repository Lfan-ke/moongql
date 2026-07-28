///|
/// Apollo Federation subgraph support (federation v1). A subgraph exposes three
/// things a gateway relies on: the `_service { sdl }` field returning the
/// subgraph's SDL with its federation directives, the `_entities(representations)`
/// resolver that turns a `{ __typename, <key fields> }` reference back into a full
/// object, and the `@key` / `@external` directives (plus `extend type` for a type
/// this subgraph does not own) that mark which types are entities and which fields
/// live elsewhere.
///
/// A `Federation` records the entity types and their reference resolvers; `apply`
/// installs the federation machinery onto a schema and its resolver map — the
/// `_Service` type, the `_Any` scalar, the `_Entity` union, and the two root
/// fields — so the ordinary executor runs a federated query with no special
/// casing.

///|
/// The reference resolver for an entity type: given a representation (a JSON
/// object carrying `__typename` and the entity's key fields) and the request
/// context, return the fully resolved entity as JSON. This is the subgraph's
/// answer to "you have a key, give me the object" — Apollo's `__resolveReference`.
pub type EntityResolver = (Json, Json) -> Json raise ResolverError

///|
/// One federated entity: its type `name`, the `key` field set (`@key(fields:)`),
/// whether the subgraph only `extends` a type it does not own, the names of its
/// `external` fields (`@external`, owned by another subgraph), and the reference
/// resolver that materialises it from a representation.
pub(all) struct EntityDef {
  name : String
  key : String
  extends : Bool
  external : Array[String]
  resolve : EntityResolver
}

///|
/// The federation configuration for a subgraph: the set of entity types it
/// contributes. Build it with `new`, register entities with `entity`, then
/// `apply` it to a schema and resolver map.
pub struct Federation {
  entities : Array[EntityDef]
}

///|
/// An empty federation config.
pub fn Federation::new() -> Federation {
  { entities: [] }
}

///|
/// Register an entity type. `name` is the object type (which must also be
/// declared on the schema), `key` is its `@key` field set (`"id"`, or space-
/// separated `"upc sku"` for a compound key), `resolve` turns a representation
/// back into the object. Set `extends` when this subgraph extends a type owned by
/// another, and list `external` fields that other subgraphs own.
pub fn Federation::entity(
  self : Federation,
  name~ : String,
  key~ : String,
  resolve~ : EntityResolver,
  extends? : Bool = false,
  external? : Array[String] = [],
) -> Unit {
  self.entities.push({ name, key, extends, external, resolve })
}

///|
/// The entity definition for a type name, if it is a registered entity.
fn Federation::entity_def(self : Federation, name : String) -> EntityDef? {
  for e in self.entities {
    if e.name == name {
      return Some(e)
    }
  }
  None
}

///|
/// The federation-internal type and field names, which the subgraph SDL omits —
/// a gateway adds them itself when composing.
fn is_federation_internal(name : String) -> Bool {
  name == "_Service" || name == "_Entity" || name == "_Any"
}

///|
/// Render the subgraph SDL: the schema as the developer wrote it, annotated with
/// `@key` on entity types (prefixed `extend` when the type is an extension),
/// `@external` on external fields, and with the federation-internal additions
/// (`_Service`, `_Entity`, `_Any`, and the `_service` / `_entities` root fields)
/// left out. This is what `_service { sdl }` returns.
pub fn Federation::sdl(self : Federation, schema : Schema) -> String {
  let mut out = ""
  for obj in schema.types {
    if is_federation_internal(obj.name) {
      continue
    }
    let ed = self.entity_def(obj.name)
    let extends = match ed {
      Some(e) => e.extends
      None => false
    }
    let external = match ed {
      Some(e) => e.external
      None => []
    }
    if extends {
      out = out + "extend "
    }
    out = out + kind_keyword(obj.kind) + " " + obj.name
    if obj.interfaces.length() > 0 {
      out = out + " implements "
      for i, iface in obj.interfaces {
        if i > 0 {
          out = out + " & "
        }
        out = out + iface
      }
    }
    match ed {
      Some(e) => out = out + " @key(fields: \"" + e.key + "\")"
      None => ()
    }
    out = out + " {\n"
    for f in obj.fields {
      if obj.name == schema.query &&
        (f.name == "_service" || f.name == "_entities") {
        continue
      }
      out = out + field_sdl(f)
      if str_in(external, f.name) {
        out = out + " @external"
      }
      out = out + "\n"
    }
    out = out + "}\n\n"
  }
  for en in schema.enums {
    out = out + "enum " + en.name + " {\n"
    for v in en.values {
      out = out + "  " + v + "\n"
    }
    out = out + "}\n\n"
  }
  for un in schema.unions {
    if is_federation_internal(un.name) {
      continue
    }
    out = out + "union " + un.name + " = "
    for i, m in un.members {
      if i > 0 {
        out = out + " | "
      }
      out = out + m
    }
    out = out + "\n\n"
  }
  for sc in schema.scalars {
    if is_federation_internal(sc.name) {
      continue
    }
    out = out + "scalar " + sc.name + "\n\n"
  }
  out
}

///|
/// Read a representation's `__typename`, or `""` when it carries none.
fn representation_typename(rep : Json) -> String {
  match rep {
    Object(m) =>
      match m.get("__typename") {
        Some(String(tn)) => tn
        _ => ""
      }
    _ => ""
  }
}

///|
/// Stamp `__typename` onto a resolved entity so the executor's union completion
/// can pick the concrete member type. A non-object value passes through unchanged.
fn tag_typename(value : Json, typename : String) -> Json {
  match value {
    Object(m) => {
      m["__typename"] = typename.to_json()
      m.to_json()
    }
    _ => value
  }
}

///|
/// Install the federation machinery onto `schema` and `resolvers`: declare the
/// `_Any` scalar, the `_Service` type with its `sdl` field, and the `_Entity`
/// union over every registered entity type; add the `_service` and `_entities`
/// fields to the query root; and register the two resolvers. After this the schema
/// answers a federated query — `{ _service { sdl } }` and
/// `_entities(representations:)` — through the normal executor.
pub fn Federation::apply(
  self : Federation,
  schema : Schema,
  resolvers : Resolvers,
) -> Unit {
  schema.scalar("_Any")
  let service = schema.object("_Service")
  service.field("sdl", NonNull(Scalar("String")))
  let members : Array[String] = []
  for e in self.entities {
    members.push(e.name)
  }
  schema.union("_Entity", members)
  match schema.type_by_name(schema.query) {
    Some(query) => {
      query.field("_service", NonNull(Named("_Service")))
      query.field_args(
        "_entities",
        [("representations", NonNull(ListOf(NonNull(Scalar("_Any")))))],
        NonNull(ListOf(Named("_Entity"))),
      )
    }
    None => ()
  }
  let fed = self
  resolvers.field("Query", "_service", fn(_info) {
    jobj([("sdl", fed.sdl(schema).to_json())])
  })
  resolvers.field("Query", "_entities", info => {
    let reps = match info.arg("representations") {
      Array(items) => items
      _ => []
    }
    let out : Array[Json] = []
    for rep in reps {
      let tn = representation_typename(rep)
      match fed.entity_def(tn) {
        Some(ed) => out.push(tag_typename((ed.resolve)(rep, info.ctx), tn))
        None => out.push(Json::null())
      }
    }
    out.to_json()
  })
}
