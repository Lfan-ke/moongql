///|
/// Document-level validation rules (GraphQL spec §5), the ones that range over the
/// whole document rather than a single selection: operation-name uniqueness and
/// the lone-anonymous-operation rule (§5.2), fragment-name uniqueness (§5.5.1.1),
/// the no-unused-fragments rule (§5.5.1.4), and cycle detection on fragment
/// spreads (§5.5.2.2), plus the variable-usage collector the per-operation checks
/// (§5.8.4) rely on. These complement the per-selection rules in `validate.mbt`.

///|
/// §5.2.1.1 (Operation Name Uniqueness) and §5.2.2.1 (Lone Anonymous Operation):
/// no two operations may share a name, and an anonymous operation must be the only
/// operation in the document.
fn Validator::check_operation_names(self : Validator, doc : Document) -> Unit {
  let names : Array[String] = []
  let mut anon = 0
  let mut total = 0
  for def in doc.definitions {
    match def {
      OperationDef(op) => {
        total = total + 1
        match op.name {
          Some(n) => {
            if str_in(names, n) {
              self.err("There can be only one operation named '" + n + "'")
            }
            names.push(n)
          }
          None => anon = anon + 1
        }
      }
      FragmentDef(_) => ()
    }
  }
  if anon > 0 && total > 1 {
    self.err(
      "This anonymous operation must be the only defined operation in the document",
    )
  }
}

///|
/// §5.5.1.1 (Fragment Name Uniqueness): no two fragment definitions may share a
/// name.
fn Validator::check_fragment_uniqueness(
  self : Validator,
  doc : Document,
) -> Unit {
  let names : Array[String] = []
  for def in doc.definitions {
    match def {
      FragmentDef(fr) => {
        if str_in(names, fr.name) {
          self.err("There can be only one fragment named '" + fr.name + "'")
        }
        names.push(fr.name)
      }
      OperationDef(_) => ()
    }
  }
}

///|
/// Collect the fragment names spread anywhere within `selections`, following the
/// spreads transitively through the fragments they reference (used to compute the
/// set of fragments reachable from an operation).
fn Validator::collect_spreads(
  self : Validator,
  selections : Array[Selection],
  out : Array[String],
) -> Unit {
  for sel in selections {
    match sel {
      FieldSel(f) => self.collect_spreads(f.selection_set, out)
      FragmentSpreadSel(name, _) =>
        if not(str_in(out, name)) {
          out.push(name)
          match self.fragments.get(name) {
            Some(fr) => self.collect_spreads(fr.selection_set, out)
            None => ()
          }
        }
      InlineFragmentSel(_, _, sels) => self.collect_spreads(sels, out)
    }
  }
}

///|
/// §5.5.1.4 (Fragments Must Be Used): every defined fragment must be spread,
/// transitively, from at least one operation.
fn Validator::check_fragments_used(self : Validator, doc : Document) -> Unit {
  let reachable : Array[String] = []
  for def in doc.definitions {
    match def {
      OperationDef(op) => self.collect_spreads(op.selection_set, reachable)
      FragmentDef(_) => ()
    }
  }
  for def in doc.definitions {
    match def {
      FragmentDef(fr) =>
        if not(str_in(reachable, fr.name)) {
          self.err("Fragment '" + fr.name + "' is never used")
        }
      OperationDef(_) => ()
    }
  }
}

///|
/// The fragment names spread directly within `selections` (descending through
/// inline fragments and fields but not following a spread into its fragment body).
fn Validator::direct_spreads(
  self : Validator,
  selections : Array[Selection],
  out : Array[String],
) -> Unit {
  for sel in selections {
    match sel {
      FieldSel(f) => self.direct_spreads(f.selection_set, out)
      FragmentSpreadSel(name, _) => if not(str_in(out, name)) { out.push(name) }
      InlineFragmentSel(_, _, sels) => self.direct_spreads(sels, out)
    }
  }
}

///|
/// Whether the fragment `current` can, by following spreads, reach `start`.
/// `visited` guards against revisiting a fragment so the walk terminates even on a
/// cyclic graph.
fn Validator::fragment_reaches(
  self : Validator,
  start : String,
  current : String,
  visited : Array[String],
) -> Bool {
  match self.fragments.get(current) {
    None => false
    Some(fr) => {
      let spreads : Array[String] = []
      self.direct_spreads(fr.selection_set, spreads)
      for s in spreads {
        if s == start {
          return true
        }
        if not(str_in(visited, s)) {
          visited.push(s)
          if self.fragment_reaches(start, s, visited) {
            return true
          }
        }
      }
      false
    }
  }
}

///|
/// §5.5.2.2 (Fragment Spreads Must Not Form Cycles): a fragment must not be able
/// to spread itself, directly or transitively.
fn Validator::check_fragment_cycles(self : Validator, doc : Document) -> Unit {
  for def in doc.definitions {
    match def {
      FragmentDef(fr) =>
        if self.fragment_reaches(fr.name, fr.name, []) {
          self.err("Fragment '" + fr.name + "' spreads itself (cycle)")
        }
      OperationDef(_) => ()
    }
  }
}

///|
/// Collect the variable names referenced inside a value, descending into list and
/// object values.
fn collect_value_variables(v : Value, out : Array[String]) -> Unit {
  match v {
    Variable(n) => if not(str_in(out, n)) { out.push(n) }
    ListValue(items) =>
      for it in items {
        collect_value_variables(it, out)
      }
    ObjectValue(fields) =>
      for kv in fields {
        collect_value_variables(kv.1, out)
      }
    _ => ()
  }
}

///|
/// Collect the variable names an operation actually uses: from field and directive
/// arguments across the selection set, following fragment spreads once each. Backs
/// the §5.8.4 "all variables used" check.
fn Validator::collect_used_variables(
  self : Validator,
  selections : Array[Selection],
  visited : Map[String, Bool],
  out : Array[String],
) -> Unit {
  for sel in selections {
    match sel {
      FieldSel(f) => {
        for a in f.arguments {
          collect_value_variables(a.value, out)
        }
        for d in f.directives {
          for a in d.arguments {
            collect_value_variables(a.value, out)
          }
        }
        self.collect_used_variables(f.selection_set, visited, out)
      }
      FragmentSpreadSel(name, dirs) => {
        for d in dirs {
          for a in d.arguments {
            collect_value_variables(a.value, out)
          }
        }
        if not(visited.get(name) is Some(true)) {
          visited[name] = true
          match self.fragments.get(name) {
            Some(fr) =>
              self.collect_used_variables(fr.selection_set, visited, out)
            None => ()
          }
        }
      }
      InlineFragmentSel(_, dirs, sels) => {
        for d in dirs {
          for a in d.arguments {
            collect_value_variables(a.value, out)
          }
        }
        self.collect_used_variables(sels, visited, out)
      }
    }
  }
}
