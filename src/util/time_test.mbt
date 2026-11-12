///|
/// Resolve date text in UTC and return `(start, end)`.
fn utc_span(text : StringView, now : Int64) -> (Int64, Int64)? {
  match @util.resolve_date_span(text, now, @time.utc_zone) {
    Some(span) => Some((span.start, span.end))
    None => None
  }
}

///|
/// Friday 2024-03-15 at 12:00:00 UTC.
const TEST_NOW : Int64 = 1710504000L

///|
test "explicit dates resolve to the whole unit" {
  // Year, month, day, hour, minute, second.
  assert_eq(utc_span("2024", TEST_NOW), Some((1704067200L, 1735689600L)))
  assert_eq(utc_span("2024-03", TEST_NOW), Some((1709251200L, 1711929600L)))
  assert_eq(utc_span("2024-03-15", TEST_NOW), Some((1710460800L, 1710547200L)))
  assert_eq(
    utc_span("2024-03-15 12", TEST_NOW),
    Some((1710504000L, 1710507600L)),
  )
  assert_eq(
    utc_span("2024-03-15 12:30", TEST_NOW),
    Some((1710505800L, 1710505860L)),
  )
  assert_eq(
    utc_span("2024-03-15 12:30:45", TEST_NOW),
    Some((1710505845L, 1710505846L)),
  )
}

///|
test "explicit dates accept separators and two-digit years" {
  // `T` is accepted instead of a space.
  assert_eq(
    utc_span("2024-03-15T12:30", TEST_NOW),
    Some((1710505800L, 1710505860L)),
  )
  // 24 maps to 2024; 99 maps to 1999.
  assert_eq(utc_span("24-03-15", TEST_NOW), Some((1710460800L, 1710547200L)))
  assert_eq(utc_span("99", TEST_NOW), Some((915148800L, 946684800L)))
  // One-digit month and day are fine.
  assert_eq(utc_span("2024-3-5", TEST_NOW), Some((1709596800L, 1709683200L)))
}

///|
test "invalid dates resolve to None" {
  assert_true(utc_span("", TEST_NOW) is None)
  assert_true(utc_span("nonsense", TEST_NOW) is None)
  assert_true(utc_span("2024-13", TEST_NOW) is None)
  assert_true(utc_span("2024-02-30", TEST_NOW) is None)
  assert_true(utc_span("2024-03-15 25", TEST_NOW) is None)
  assert_true(utc_span("2024-03-15 12:60", TEST_NOW) is None)
  assert_true(utc_span("2024-03-15 12:30:60", TEST_NOW) is None)
  assert_true(utc_span("2024-03-15 x", TEST_NOW) is None)
  assert_true(utc_span("202", TEST_NOW) is None)
}

///|
test "today and yesterday are whole days" {
  assert_eq(utc_span("today", TEST_NOW), Some((1710460800L, 1710547200L)))
  assert_eq(utc_span("yesterday", TEST_NOW), Some((1710374400L, 1710460800L)))
  // Case-insensitive.
  assert_eq(utc_span("TODAY", TEST_NOW), Some((1710460800L, 1710547200L)))
}

///|
test "weekday names pick the most recent occurrence" {
  // TEST_NOW is a Friday; the most recent Monday is 2024-03-11.
  assert_eq(utc_span("monday", TEST_NOW), Some((1710115200L, 1710201600L)))
  assert_eq(utc_span("mon", TEST_NOW), utc_span("monday", TEST_NOW))
  // Friday itself is today.
  assert_eq(utc_span("fri", TEST_NOW), utc_span("today", TEST_NOW))
  // The previous Sunday was 2024-03-10.
  assert_eq(utc_span("sunday", TEST_NOW), Some((1710028800L, 1710115200L)))
}

///|
test "month names pick the most recent occurrence" {
  // March is the current month.
  assert_eq(utc_span("mar", TEST_NOW), Some((1709251200L, 1711929600L)))
  // January is earlier this year.
  assert_eq(utc_span("january", TEST_NOW), Some((1704067200L, 1706745600L)))
  // December last happened in 2023.
  assert_eq(utc_span("dec", TEST_NOW), Some((1701388800L, 1704067200L)))
}

///|
test "relative last forms are rolling windows ending now" {
  assert_eq(utc_span("lastweek", TEST_NOW), Some((1709899200L, TEST_NOW)))
  assert_eq(utc_span("lastfiveweeks", TEST_NOW), Some((1707480000L, TEST_NOW)))
  assert_eq(utc_span("last5weeks", TEST_NOW), Some((1707480000L, TEST_NOW)))
  assert_eq(utc_span("last3days", TEST_NOW), Some((1710244800L, TEST_NOW)))
  assert_eq(
    utc_span("inthelast2hours", TEST_NOW),
    Some((1710496800L, TEST_NOW)),
  )
  assert_eq(utc_span("previousmonth", TEST_NOW), Some((1707998400L, TEST_NOW)))
}

///|
test "this forms select the current calendar unit" {
  assert_eq(utc_span("thismonth", TEST_NOW), Some((1709251200L, 1711929600L)))
  assert_eq(utc_span("thisyear", TEST_NOW), Some((1704067200L, 1735689600L)))
  // Friday 2024-03-15 belongs to the week of Monday 2024-03-11.
  assert_eq(utc_span("thisweek", TEST_NOW), Some((1710115200L, 1710720000L)))
  assert_eq(utc_span("thisday", TEST_NOW), utc_span("today", TEST_NOW))
  assert_eq(utc_span("thishour", TEST_NOW), Some((1710504000L, 1710507600L)))
}

///|
test "date resolution honours the supplied time zone" {
  let plus_one = @time.fixed_zone("Test", 3600) catch {
    _ => abort("could not build a fixed zone")
  }
  let span = match @util.resolve_date_span("today", TEST_NOW, plus_one) {
    Some(span) => Some((span.start, span.end))
    None => None
  }
  // Local midnight at UTC+1 is 23:00 the previous day in UTC.
  assert_eq(span, Some((1710457200L, 1710543600L)))
  let explicit = match
    @util.resolve_date_span("2024-03-15 12:00", TEST_NOW, plus_one) {
    Some(span) => Some((span.start, span.end))
    None => None
  }
  assert_eq(explicit, Some((1710500400L, 1710500460L)))
}

///|
test "trimmed whitespace is accepted" {
  assert_eq(utc_span("  2024-03  ", TEST_NOW), Some((1709251200L, 1711929600L)))
}
