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
  // `past` is the plan's alias for the same rolling window as `last`.
  assert_eq(utc_span("pastweek", TEST_NOW), utc_span("lastweek", TEST_NOW))
  assert_eq(utc_span("past3days", TEST_NOW), utc_span("last3days", TEST_NOW))
  assert_eq(
    utc_span("pastfiveweeks", TEST_NOW),
    utc_span("lastfiveweeks", TEST_NOW),
  )
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
/// Resolve date text in `zone` and return `(start, end)`.
fn zone_span(
  text : StringView,
  now : Int64,
  zone : @time.Zone,
) -> (Int64, Int64)? {
  match @util.resolve_date_span(text, now, zone) {
    Some(span) => Some((span.start, span.end))
    None => None
  }
}

///|
/// America/New_York from the embedded IANA tz database fixture (see
/// `testdata/README.md`). Embedding the zone instead of reading the host's
/// `/usr/share/zoneinfo` keeps the DST expectations identical on every CI OS.
fn new_york_zone() -> @time.Zone {
  @time.Zone::from_tzif("America/New_York", new_york_tzif) catch {
    err => abort("cannot load the embedded America/New_York zone: \{err}")
  }
}

///|
test "DST transition days are 23 and 25 hours long" {
  let zone = new_york_zone()
  // 2024-03-10: EST (UTC-5) changes to EDT (UTC-4) at 07:00 UTC.
  let spring = zone_span("2024-03-10", TEST_NOW, zone).unwrap()
  assert_eq(spring, (1710046800L, 1710129600L))
  assert_eq(spring.1 - spring.0, 23L * 3600L)
  // 2024-11-03: EDT (UTC-4) changes back to EST (UTC-5) at 06:00 UTC.
  let fall = zone_span("2024-11-03", TEST_NOW, zone).unwrap()
  assert_eq(fall, (1730606400L, 1730696400L))
  assert_eq(fall.1 - fall.0, 25L * 3600L)
  // Calendar-relative forms use the same local day, not a 24-hour window.
  assert_eq(zone_span("today", 1710086400L, zone), Some(spring))
  assert_eq(zone_span("thisday", 1730649600L, zone), Some(fall))
  // Neighbouring days are ordinary 24-hour days.
  let march_ninth = zone_span("2024-03-09", TEST_NOW, zone).unwrap()
  let november_fourth = zone_span("2024-11-04", TEST_NOW, zone).unwrap()
  assert_eq(march_ninth.1 - march_ninth.0, 24L * 3600L)
  assert_eq(november_fourth.1 - november_fourth.0, 24L * 3600L)
}

///|
test "nonexistent local times resolve compatibly forward" {
  let zone = new_york_zone()
  // 02:30 does not exist on 2024-03-10. The default Compatible policy shifts
  // it forward by the one-hour gap, so the span starts at 03:30 EDT.
  assert_eq(
    zone_span("2024-03-10 02:30", TEST_NOW, zone),
    Some((1710055800L, 1710055860L)),
  )
  let shifted = @time.date_time(2024, 3, 10, hour=2, minute=30, zone~) catch {
    err => abort("compatible disambiguation must not raise: \{err}")
  }
  assert_eq(shifted.hour(), 3)
  assert_eq(shifted.minute(), 30)
  // `Reject` surfaces the gap instead of guessing.
  let rejected = try {
    let _ = @time.date_time(
      2024,
      3,
      10,
      hour=2,
      minute=30,
      zone~,
      disambiguation=@time.Reject,
    )
    false
  } catch {
    _ => true
  }
  assert_true(rejected)
}

///|
test "ambiguous local times resolve to the earlier offset" {
  let zone = new_york_zone()
  // 01:30 happens twice on 2024-11-03. Compatible picks the first occurrence
  // (EDT, UTC-4), while Later picks the second (EST, UTC-5).
  assert_eq(
    zone_span("2024-11-03 01:30", TEST_NOW, zone),
    Some((1730611800L, 1730611860L)),
  )
  let earlier = @time.date_time(
    2024,
    11,
    3,
    hour=1,
    minute=30,
    zone~,
    disambiguation=@time.Earlier,
  ) catch {
    err => abort("earlier disambiguation must not raise: \{err}")
  }
  let later = @time.date_time(
    2024,
    11,
    3,
    hour=1,
    minute=30,
    zone~,
    disambiguation=@time.Later,
  ) catch {
    err => abort("later disambiguation must not raise: \{err}")
  }
  assert_eq(earlier.to_unix_second(), 1730611800L)
  assert_eq(later.to_unix_second(), 1730615400L)
  assert_eq(later.to_unix_second() - earlier.to_unix_second(), 3600L)
}

///|
test "fixed zones keep every day 24 hours long" {
  // A fixed offset has no transitions, so even a date that is a DST day in a
  // real zone stays a 24-hour day here. This pins the "fixed TZ" contrast.
  let fixed = @time.fixed_zone("Test", -5 * 3600) catch {
    _ => abort("could not build a fixed zone")
  }
  let spring = zone_span("2024-03-10", TEST_NOW, fixed).unwrap()
  assert_eq(spring.1 - spring.0, 24L * 3600L)
  let fall = zone_span("2024-11-03", TEST_NOW, fixed).unwrap()
  assert_eq(fall.1 - fall.0, 24L * 3600L)
  assert_eq(
    zone_span("2024-03-10 02:30", TEST_NOW, fixed),
    Some((1710055800L, 1710055860L)),
  )
}

///|
test "trimmed whitespace is accepted" {
  assert_eq(utc_span("  2024-03  ", TEST_NOW), Some((1709251200L, 1711929600L)))
}
