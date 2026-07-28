///|
/// A GraphQL type reference: a scalar (`String`, `Int`, `Boolean`, `Float`, `ID`),
/// a named object type, or a non-null / list wrapper around another type.
pub(all) enum GqlType {
  Scalar(String)
  Named(String)
  NonNull(GqlType)
  ListOf(GqlType)
} derive(Eq)

///|
/// Render a type reference to GraphQL SDL notation (`String!`, `[User!]`, ...).
fn type_sdl(t : GqlType) -> String {
  match t {
    Scalar(s) => s
    Named(n) => n
    NonNull(inner) => type_sdl(inner) + "!"
    ListOf(inner) => "[" + type_sdl(inner) + "]"
  }
}

///|
/// A field on an object type: a name and its type.
pub(all) struct Field {
  name : String
  typ : GqlType
}

///|
/// A GraphQL object type with an ordered set of fields.
pub(all) struct ObjectType {
  name : String
  fields : Array[Field]
}

///|
/// Add a field to this object type.
pub fn ObjectType::field(
  self : ObjectType,
  name : String,
  typ : GqlType,
) -> Unit {
  self.fields.push({ name, typ })
}

///|
/// A code-first GraphQL schema: a set of object types plus the name of the root
/// query type.
pub struct Schema {
  types : Array[ObjectType]
  query : String
}

///|
/// Create an empty schema whose root query type is `query` (default `Query`).
pub fn Schema::new(query? : String = "Query") -> Schema {
  { types: [], query }
}

///|
/// Declare an object type and return it so fields can be added. The type is
/// registered in the schema by reference, so later `.field(...)` calls are seen.
pub fn Schema::object(self : Schema, name : String) -> ObjectType {
  let o : ObjectType = { name, fields: [] }
  self.types.push(o)
  o
}

///|
/// Emit the schema as GraphQL SDL: a `schema { query: ... }` block followed by a
/// `type` block per object type.
pub fn Schema::to_sdl(self : Schema) -> String {
  let mut out = "schema {\n  query: " + self.query + "\n}\n\n"
  for obj in self.types {
    out = out + "type " + obj.name + " {\n"
    for f in obj.fields {
      out = out + "  " + f.name + ": " + type_sdl(f.typ) + "\n"
    }
    out = out + "}\n\n"
  }
  out
}
