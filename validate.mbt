///|
/// The GraphQL validator (spec §5, the subset that matters before execution):
/// every selected field exists on its parent type, leaf fields carry no
/// sub-selection while composite fields require one, field arguments are declared
/// (and required arguments supplied), fragment spreads name existing fragments,
/// fragment type conditions name existing types, and every referenced variable
/// is defined with a type that exists. Errors are collected, not raised, so
/// `execute` can report them all in one `{ errors }` response.

///|
/// Validator state: the schema, the document's fragments, and the error list.
priv struct Validator {
  schema : Schema
  fragments : Map[String, FragmentDefinition]
  errors : Array[GqlError]
}

///|
/// Look up an output object/interface/input or synthetic introspection type.
fn Validator::lookup_type(self : Validator, name : String) -> ObjectType? {
  match self.schema.type_by_name(name) {
    Some(t) => Some(t)
    None => introspection_type_def(name)
  }
}

///|
/// Whether `name` is a leaf type (scalar or enum) with no selectable subfields.
fn Validator::is_leaf(self : Validator, name : String) -> Bool {
  is_builtin_scalar(name) ||
  self.schema.enum_by_name(name) is Some(_) ||
  self.schema.scalar_by_name(name) is Some(_) ||
  name == "__TypeKind" ||
  name == "__DirectiveLocation"
}

///|
/// The base named type of a query-grammar `TypeRef` (unwrapping `!` and `[]`).
fn typeref_base(t : TypeRef) -> String {
  match t {
    NamedType(n) => n
    ListType(inner) => typeref_base(inner)
    NonNullType(inner) => typeref_base(inner)
  }
}

///|
/// Whether `needle` occurs in `hay`.
fn str_in(hay : Array[String], needle : String) -> Bool {
  for s in hay {
    if s == needle {
      return true
    }
  }
  false
}

///|
/// Record a message-only validation error.
fn Validator::err(self : Validator, message : String) -> Unit {
  self.errors.push(GqlError::msg(message))
}

///|
/// Check every `$variable` referenced by a value is defined (when `defined` is
/// `Some`; fragment bodies pass `None` since their variables come from the
/// operation that spreads them).
fn Validator::check_value_vars(
  self : Validator,
  v : Value,
  defined : Array[String]?,
) -> Unit {
  match defined {
    None => return
    Some(names) =>
      match v {
        Variable(n) =>
          if not(str_in(names, n)) {
            self.err("Variable '$" + n + "' is not defined")
          }
        ListValue(items) =>
          for it in items {
            self.check_value_vars(it, defined)
          }
        ObjectValue(fields) =>
          for kv in fields {
            self.check_value_vars(kv.1, defined)
          }
        _ => ()
      }
  }
}

///|
/// The valid locations of the directive `name`: a built-in executable directive
/// (`@skip`/`@include`) or a user-registered one, else `None` for an undefined
/// directive.
fn Validator::directive_locations(
  self : Validator,
  name : String,
) -> Array[String]? {
  match builtin_exec_directive(name) {
    Some(locs) => Some(locs)
    None =>
      match self.schema.directive_def_by_name(name) {
        Some(d) => Some(d.locations)
        None => None
      }
  }
}

///|
/// Whether the directive `name` is repeatable (may appear more than once at one
/// location). Built-ins are not repeatable.
fn Validator::directive_repeatable(self : Validator, name : String) -> Bool {
  match self.schema.directive_def_by_name(name) {
    Some(d) => d.is_repeatable
    None => false
  }
}

///|
/// Report duplicate argument names in an argument list (spec §5.4.2, Argument
/// Uniqueness), for a field or a directive named `owner`.
fn Validator::check_arg_uniqueness(
  self : Validator,
  args : Array[Argument],
  owner : String,
) -> Unit {
  let seen : Array[String] = []
  for a in args {
    if str_in(seen, a.name) {
      self.err("Duplicate argument '" + a.name + "' on '" + owner + "'")
    }
    seen.push(a.name)
  }
}

///|
/// Validate a directive list at type-system/executable `location`: every directive
/// is defined (§5.7.1), used at an allowed location (§5.7.2), and — unless declared
/// repeatable — appears at most once (§5.7.3); its arguments are unique (§5.4.2)
/// and their variable references are defined.
fn Validator::check_directives(
  self : Validator,
  directives : Array[Directive],
  defined : Array[String]?,
  location : String,
) -> Unit {
  let seen : Array[String] = []
  for d in directives {
    self.check_arg_uniqueness(d.arguments, "@" + d.name)
    for a in d.arguments {
      self.check_value_vars(a.value, defined)
    }
    match self.directive_locations(d.name) {
      None => self.err("Unknown directive '@" + d.name + "'")
      Some(locs) =>
        if not(str_in(locs, location)) {
          self.err("Directive '@" + d.name + "' may not be used on " + location)
        }
    }
    if str_in(seen, d.name) && not(self.directive_repeatable(d.name)) {
      self.err(
        "Directive '@" +
        d.name +
        "' can only be used once at this location (it is not repeatable)",
      )
    }
    seen.push(d.name)
  }
}

///|
/// Validate the arguments of a field against its declared argument list: every
/// supplied argument must be declared, every non-null argument must be supplied,
/// and every argument value's variables must be defined.
fn Validator::check_field_args(
  self : Validator,
  field : QueryField,
  fdef : Field,
  defined : Array[String]?,
) -> Unit {
  self.check_arg_uniqueness(field.arguments, field.name)
  let declared : Array[String] = []
  for a in fdef.args {
    declared.push(a.0)
  }
  for a in field.arguments {
    if not(str_in(declared, a.name)) {
      self.err(
        "Unknown argument '" + a.name + "' on field '" + field.name + "'",
      )
    }
    self.check_value_vars(a.value, defined)
  }
  for da in fdef.args {
    if da.1 is NonNull(_) {
      let mut supplied = false
      for a in field.arguments {
        if a.name == da.0 {
          supplied = true
        }
      }
      if not(supplied) {
        self.err(
          "Field '" +
          field.name +
          "' is missing required argument '" +
          da.0 +
          "'",
        )
      }
    }
  }
}

///|
/// Validate a selection set against the object type named `type_name`.
fn Validator::check_selection_set(
  self : Validator,
  type_name : String,
  selections : Array[Selection],
  defined : Array[String]?,
) -> Unit {
  match self.schema.union_by_name(type_name) {
    Some(u) => {
      self.check_union_selection_set(type_name, u, selections, defined)
      return
    }
    None => ()
  }
  let obj = match self.lookup_type(type_name) {
    Some(o) => o
    None => {
      self.err("Cannot select on unknown type '" + type_name + "'")
      return
    }
  }
  for sel in selections {
    match sel {
      FieldSel(f) => {
        self.check_directives(f.directives, defined, "FIELD")
        if f.name == "__typename" {
          if f.selection_set.length() > 0 {
            self.err("Field '__typename' must not have a selection set")
          }
          continue
        }
        if type_name == self.schema.query &&
          (f.name == "__schema" || f.name == "__type") {
          let meta = if f.name == "__schema" { "__Schema" } else { "__Type" }
          for a in f.arguments {
            self.check_value_vars(a.value, defined)
          }
          if f.selection_set.length() == 0 {
            self.err(
              "Field '" + f.name + "' must have a selection of subfields",
            )
          } else {
            self.check_selection_set(meta, f.selection_set, defined)
          }
          continue
        }
        match obj.field_by_name(f.name) {
          None =>
            self.err(
              "Cannot query field '" + f.name + "' on type '" + type_name + "'",
            )
          Some(fdef) => {
            self.check_field_args(f, fdef, defined)
            let base = fdef.typ.named_base()
            if self.is_leaf(base) {
              if f.selection_set.length() > 0 {
                self.err(
                  "Field '" +
                  f.name +
                  "' of leaf type '" +
                  base +
                  "' must not have a selection set",
                )
              }
            } else if self.schema.union_by_name(base) is Some(u) {
              if f.selection_set.length() == 0 {
                self.err(
                  "Field '" +
                  f.name +
                  "' of union type '" +
                  base +
                  "' must have a selection of subfields",
                )
              } else {
                self.check_union_selection_set(
                  base,
                  u,
                  f.selection_set,
                  defined,
                )
              }
            } else if self.lookup_type(base) is Some(_) {
              if f.selection_set.length() == 0 {
                self.err(
                  "Field '" +
                  f.name +
                  "' of type '" +
                  base +
                  "' must have a selection of subfields",
                )
              } else {
                self.check_selection_set(base, f.selection_set, defined)
              }
            } else {
              self.err("Field '" + f.name + "' has unknown type '" + base + "'")
            }
          }
        }
      }
      FragmentSpreadSel(name, dirs) => {
        self.check_directives(dirs, defined, "FRAGMENT_SPREAD")
        if not(self.fragments.contains(name)) {
          self.err("Unknown fragment '" + name + "'")
        }
      }
      InlineFragmentSel(cond, dirs, sels) => {
        self.check_directives(dirs, defined, "INLINE_FRAGMENT")
        let cond_type = match cond {
          Some(c) => c
          None => type_name
        }
        if self.type_exists(cond_type) {
          self.check_selection_set(cond_type, sels, defined)
        } else {
          self.err("Inline fragment on unknown type '" + cond_type + "'")
        }
      }
    }
  }
}

///|
/// Validate a selection set at a union position: only `__typename` and fragments
/// on member types (or the union itself) may select into a union. A direct field
/// selection other than `__typename` is an error.
fn Validator::check_union_selection_set(
  self : Validator,
  union_name : String,
  u : UnionType,
  selections : Array[Selection],
  defined : Array[String]?,
) -> Unit {
  for sel in selections {
    match sel {
      FieldSel(f) => {
        self.check_directives(f.directives, defined, "FIELD")
        if f.name == "__typename" {
          if f.selection_set.length() > 0 {
            self.err("Field '__typename' must not have a selection set")
          }
        } else {
          self.err(
            "Cannot query field '" +
            f.name +
            "' directly on union type '" +
            union_name +
            "'; select it inside an inline fragment on a member type",
          )
        }
      }
      FragmentSpreadSel(name, dirs) => {
        self.check_directives(dirs, defined, "FRAGMENT_SPREAD")
        if not(self.fragments.contains(name)) {
          self.err("Unknown fragment '" + name + "'")
        }
      }
      InlineFragmentSel(cond, dirs, sels) => {
        self.check_directives(dirs, defined, "INLINE_FRAGMENT")
        let cond_type = match cond {
          Some(c) => c
          None => union_name
        }
        if cond_type == union_name {
          self.check_union_selection_set(union_name, u, sels, defined)
        } else if str_in(u.members, cond_type) {
          self.check_selection_set(cond_type, sels, defined)
        } else {
          self.err(
            "Inline fragment type '" +
            cond_type +
            "' is not a member of union '" +
            union_name +
            "'",
          )
        }
      }
    }
  }
}

///|
/// Whether a name denotes a selectable type: a composite/introspection type or a
/// union. Used to accept union type conditions on fragments.
fn Validator::type_exists(self : Validator, name : String) -> Bool {
  self.lookup_type(name) is Some(_) ||
  self.schema.union_by_name(name) is Some(_)
}

///|
/// Validate a single operation: its root type must be configured, its variable
/// definitions must name existing input types, and its selection set must be
/// valid.
fn Validator::check_operation(
  self : Validator,
  op : OperationDefinition,
) -> Unit {
  let root = match op.operation {
    Query => Some(self.schema.query)
    Mutation => self.schema.mutation
    Subscription => self.schema.subscription
  }
  let root_type = match root {
    Some(r) => r
    None => {
      self.err("Schema has no root type for this operation")
      return
    }
  }
  let op_location = match op.operation {
    Query => "QUERY"
    Mutation => "MUTATION"
    Subscription => "SUBSCRIPTION"
  }
  self.check_directives(op.directives, None, op_location)
  let defined : Array[String] = []
  for vd in op.variable_definitions {
    // §5.8.1 Variable Uniqueness: a variable name is defined at most once.
    if str_in(defined, vd.variable) {
      self.err("Duplicate variable '$" + vd.variable + "'")
    }
    defined.push(vd.variable)
    self.check_directives(vd.directives, Some(defined), "VARIABLE_DEFINITION")
    let base = typeref_base(vd.typ)
    // §5.8.2 Variables Are Input Types: a variable's type must be a scalar, enum,
    // or input object — never an output object, interface, or union.
    let is_input_type = is_builtin_scalar(base) ||
      self.schema.enum_by_name(base) is Some(_) ||
      self.schema.scalar_by_name(base) is Some(_) ||
      (self.schema.type_by_name(base) is Some(t) && t.kind is Input)
    if !is_input_type {
      let exists = self.schema.type_by_name(base) is Some(_) ||
        self.schema.union_by_name(base) is Some(_)
      if exists {
        self.err(
          "Variable '$" +
          vd.variable +
          "' cannot be non-input type '" +
          base +
          "'",
        )
      } else {
        self.err(
          "Variable '$" + vd.variable + "' has unknown type '" + base + "'",
        )
      }
    }
  }
  if op.operation is Subscription {
    self.check_single_root_field(op)
  }
  self.check_selection_set(root_type, op.selection_set, Some(defined))
  // §5.8.4 All Variables Used: every defined variable is referenced somewhere in
  // the operation (directly or through a spread fragment).
  let used : Array[String] = []
  self.collect_used_variables(op.selection_set, Map([]), used)
  for vd in op.variable_definitions {
    if not(str_in(used, vd.variable)) {
      self.err("Variable '$" + vd.variable + "' is never used")
    }
  }
}

///|
/// SingleRootField (spec §5.2.3.1): a subscription must select exactly one root
/// field after fragment expansion, and it must not be an introspection field.
fn Validator::check_single_root_field(
  self : Validator,
  op : OperationDefinition,
) -> Unit {
  let fields : Array[QueryField] = []
  self.collect_root_fields(op.selection_set, Map([]), fields)
  let keys : Array[String] = []
  for f in fields {
    let key = match f.alias_ {
      Some(a) => a
      None => f.name
    }
    if not(str_in(keys, key)) {
      keys.push(key)
    }
  }
  if keys.length() != 1 {
    self.err("Subscription operation must select exactly one root field")
  } else if is_meta_field(fields[0].name) {
    self.err(
      "Subscription root field '" +
      fields[0].name +
      "' must not be an introspection field",
    )
  }
}

///|
/// Gather the root-level fields of a selection set, expanding fragment spreads
/// and inline fragments (used to count a subscription's root fields).
fn Validator::collect_root_fields(
  self : Validator,
  selections : Array[Selection],
  visited : Map[String, Bool],
  out : Array[QueryField],
) -> Unit {
  for sel in selections {
    match sel {
      FieldSel(f) => out.push(f)
      FragmentSpreadSel(name, _) =>
        if not(visited.get(name) is Some(true)) {
          visited[name] = true
          match self.fragments.get(name) {
            Some(frag) =>
              self.collect_root_fields(frag.selection_set, visited, out)
            None => ()
          }
        }
      InlineFragmentSel(_, _, sels) =>
        self.collect_root_fields(sels, visited, out)
    }
  }
}

///|
/// Validate a fragment definition: its type condition must exist, and its body
/// must be valid against that type. Variable references inside are checked at the
/// operations that spread it.
fn Validator::check_fragment(
  self : Validator,
  frag : FragmentDefinition,
) -> Unit {
  self.check_directives(frag.directives, None, "FRAGMENT_DEFINITION")
  if self.type_exists(frag.type_condition) {
    self.check_selection_set(frag.type_condition, frag.selection_set, None)
  } else {
    self.err(
      "Fragment '" +
      frag.name +
      "' has unknown type condition '" +
      frag.type_condition +
      "'",
    )
  }
}

///|
/// Validate a whole document against `schema`, returning all errors found (an
/// empty array means the document is valid and ready to execute).
pub fn validate(schema : Schema, doc : Document) -> Array[GqlError] {
  let v = { schema, fragments: collect_fragments(doc), errors: [] }
  v.check_operation_names(doc)
  v.check_fragment_uniqueness(doc)
  v.check_fragment_cycles(doc)
  let mut has_op = false
  for def in doc.definitions {
    match def {
      OperationDef(op) => {
        has_op = true
        v.check_operation(op)
      }
      FragmentDef(frag) => v.check_fragment(frag)
    }
  }
  if not(has_op) {
    v.err("Document contains no operations")
  }
  v.check_fragments_used(doc)
  v.errors
}
