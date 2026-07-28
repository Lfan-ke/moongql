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
/// A field on an object type: a name, an ordered list of arguments (each a
/// `(name, type)` pair), and the field's return type. A field with no arguments
/// prints as `name: Type`; with arguments it prints as `name(a: A, b: B): Type`.
pub(all) struct Field {
  name : String
  args : Array[(String, GqlType)]
  typ : GqlType
}

///|
/// Render a single field to SDL, including its argument list when non-empty.
fn field_sdl(f : Field) -> String {
  let mut out = "  " + f.name
  if f.args.length() > 0 {
    out = out + "("
    for i, arg in f.args {
      let (an, at) = arg
      if i > 0 {
        out = out + ", "
      }
      out = out + an + ": " + type_sdl(at)
    }
    out = out + ")"
  }
  out + ": " + type_sdl(f.typ)
}

///|
/// Which kind of composite type an `ObjectType` describes: an output `object`
/// (`type`), an `input` object, or an `interface`.
pub(all) enum TypeKind {
  Object
  Input
  Interface
} derive(Eq)

///|
/// A GraphQL composite type with an ordered set of fields. The same shape backs
/// output objects, input objects, and interfaces; `kind` selects the SDL keyword
/// and `interfaces` lists the interfaces an object implements.
pub(all) struct ObjectType {
  name : String
  fields : Array[Field]
  kind : TypeKind
  interfaces : Array[String]
}

///|
/// Add a field with no arguments to this type.
pub fn ObjectType::field(
  self : ObjectType,
  name : String,
  typ : GqlType,
) -> Unit {
  self.fields.push({ name, args: [], typ })
}

///|
/// Add a field carrying arguments to this type. Each argument is a `(name, type)`
/// pair and renders as `name(a: A, b: B): RetType`.
pub fn ObjectType::field_args(
  self : ObjectType,
  name : String,
  args : Array[(String, GqlType)],
  typ : GqlType,
) -> Unit {
  self.fields.push({ name, args, typ })
}

///|
/// Declare that this object type implements a named interface. Implemented
/// interfaces render as `type Name implements A & B { ... }`.
pub fn ObjectType::implements(self : ObjectType, name : String) -> Unit {
  self.interfaces.push(name)
}

///|
/// A GraphQL enum type: a name and an ordered list of value names.
pub(all) struct EnumType {
  name : String
  values : Array[String]
}

///|
/// A code-first GraphQL schema: composite types (objects, inputs, interfaces),
/// enum types, plus the name of the root query type.
pub struct Schema {
  types : Array[ObjectType]
  enums : Array[EnumType]
  query : String
}

///|
/// Create an empty schema whose root query type is `query` (default `Query`).
pub fn Schema::new(query? : String = "Query") -> Schema {
  { types: [], enums: [], query }
}

///|
/// Declare an output object type and return it so fields can be added. The type
/// is registered by reference, so later `.field(...)` calls are seen.
pub fn Schema::object(self : Schema, name : String) -> ObjectType {
  let o : ObjectType = { name, fields: [], kind: Object, interfaces: [] }
  self.types.push(o)
  o
}

///|
/// Declare an input object type and return it so fields can be added. Renders as
/// `input Name { ... }`.
pub fn Schema::input(self : Schema, name : String) -> ObjectType {
  let o : ObjectType = { name, fields: [], kind: Input, interfaces: [] }
  self.types.push(o)
  o
}

///|
/// Declare an interface type and return it so fields can be added. Renders as
/// `interface Name { ... }`; objects declare conformance via `implements`.
pub fn Schema::interface(self : Schema, name : String) -> ObjectType {
  let o : ObjectType = { name, fields: [], kind: Interface, interfaces: [] }
  self.types.push(o)
  o
}

///|
/// Declare an enum type with an ordered set of value names. Renders as
/// `enum Name { A B }` with one value per line.
pub fn Schema::enum_(
  self : Schema,
  name : String,
  values : Array[String],
) -> Unit {
  self.enums.push({ name, values })
}

///|
/// The SDL keyword introducing a composite type of the given kind.
fn kind_keyword(k : TypeKind) -> String {
  match k {
    Object => "type"
    Input => "input"
    Interface => "interface"
  }
}

///|
/// Emit the schema as GraphQL SDL: a `schema { query: ... }` block, then one
/// block per composite type (`type` / `input` / `interface`, with `implements`
/// and field arguments), then one block per enum type.
pub fn Schema::to_sdl(self : Schema) -> String {
  let mut out = "schema {\n  query: " + self.query + "\n}\n\n"
  for obj in self.types {
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
    out = out + " {\n"
    for f in obj.fields {
      out = out + field_sdl(f) + "\n"
    }
    out = out + "}\n\n"
  }
  for en in self.enums {
    out = out + "enum " + en.name + " {\n"
    for v in en.values {
      out = out + "  " + v + "\n"
    }
    out = out + "}\n\n"
  }
  out
}
