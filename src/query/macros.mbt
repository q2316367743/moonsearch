///|
/// A named query fragment.
///
/// Typing `name:` in a query expands the macro into its stored query. Macros are
/// how the configuration layer exposes reusable filters (the built-in document,
/// image, audio, and video categories are macros whose queries are `ext:` lists).
///
/// `flags` are the defaults for the macro's own terms. A macro is parsed
/// independently of the query that uses it, so modifiers written around the
/// expansion do not leak into it.
pub(all) struct Macro {
  name : String
  query : String
  flags : Flags
}

///|
/// Build a macro.
pub fn Macro::new(
  name~ : StringView,
  query~ : StringView,
  flags~ : Flags = Flags::new(),
) -> Macro {
  { name: "\{name}", query: "\{query}", flags, }
}

///|
/// A macro table.
///
/// Names are looked up ASCII case-insensitively, matching field names. A macro
/// name must not contain `:`; that character separates a field from its value.
pub struct Macros {
  priv entries : Map[String, Macro]
}

///|
/// Create an empty table.
pub fn Macros::new() -> Macros {
  { entries: Map([]), }
}

///|
/// Build a table from a list of macros. Later entries replace earlier ones with
/// the same name.
pub fn Macros::from_array(macros : Array[Macro]) -> Macros {
  let table = Macros::new()
  for entry in macros {
    table.set(entry)
  }
  table
}

///|
/// Add or replace a macro.
pub fn Macros::set(self : Macros, entry : Macro) -> Unit {
  self.entries.set(ascii_lower_string(entry.name), entry)
}

///|
/// Look up a macro by name.
pub fn Macros::get(self : Macros, name : StringView) -> Macro? {
  self.entries.get(ascii_lower_string(name))
}

///|
/// Whether the table has no macros.
pub fn Macros::is_empty(self : Macros) -> Bool {
  self.entries.length() == 0
}
