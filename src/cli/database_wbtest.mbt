///|
/// Build a lookup over a fixed environment map.
fn lookup_of(values : Map[String, String]) -> (String) -> String? {
  fn(name) { values.get(name) }
}

///|
test "data home prefers XDG_DATA_HOME" {
  let lookup = lookup_of(
    Map([
      ("XDG_DATA_HOME", "/xdg"),
      ("HOME", "/home/u"),
      ("LOCALAPPDATA", "C:/Users/u/AppData/Local"),
    ]),
  )
  assert_eq(resolve_data_home(lookup), Ok("/xdg"))
}

///|
test "data home falls back to HOME/.local/share" {
  let lookup = lookup_of(
    Map([("HOME", "/home/u"), ("LOCALAPPDATA", "C:/Users/u/AppData/Local")]),
  )
  assert_eq(resolve_data_home(lookup), Ok("/home/u/.local/share"))
}

///|
test "data home falls back to LOCALAPPDATA on Windows" {
  let lookup = lookup_of(
    Map([
      ("LOCALAPPDATA", "C:/Users/u/AppData/Local"),
      ("USERPROFILE", "C:/Users/u"),
    ]),
  )
  assert_eq(resolve_data_home(lookup), Ok("C:/Users/u/AppData/Local"))
}

///|
test "data home falls back to USERPROFILE/.local/share" {
  let lookup = lookup_of(Map([("USERPROFILE", "C:/Users/u")]))
  assert_eq(resolve_data_home(lookup), Ok("C:/Users/u/.local/share"))
}

///|
test "data home reports a missing environment" {
  let lookup = lookup_of(Map([]))
  assert_true(resolve_data_home(lookup) is Err(_))
}

///|
test "home resolution prefers HOME and falls back to USERPROFILE" {
  assert_eq(
    resolve_home(
      lookup_of(Map([("HOME", "/home/u"), ("USERPROFILE", "C:/Users/u")])),
    ),
    Some("/home/u"),
  )
  assert_eq(
    resolve_home(lookup_of(Map([("USERPROFILE", "C:/Users/u")]))),
    Some("C:/Users/u"),
  )
  assert_eq(resolve_home(lookup_of(Map([]))), None)
}
