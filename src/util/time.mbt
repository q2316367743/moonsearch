///|
/// A half-open interval of Unix seconds produced by resolving a date
/// expression.
///
/// `start` is inclusive and `end` is exclusive, so a whole day is
/// `[00:00, next day 00:00)`. Calendar arithmetic is done in the zone passed to
/// `resolve_date_span`, which makes a day 23 or 25 hours long across a daylight
/// saving transition.
pub(all) struct DateSpan {
  start : Int64
  end : Int64
}

///|
/// Build a date span.
pub fn DateSpan::new(start : Int64, end : Int64) -> DateSpan {
  { start, end, }
}

///|
/// Current Unix time in whole seconds.
pub fn current_unix_seconds() -> Int64 {
  (@env.now() / 1000UL).reinterpret_as_int64()
}

///|
/// The host's local time zone, or UTC when the host cannot resolve one.
///
/// Date queries are evaluated in local time. Falling back to UTC keeps a
/// malformed time zone database from turning every query into an error.
pub fn local_zone() -> @time.Zone {
  @time.local_zone() catch {
    _ => @time.utc_zone
  }
}

///|
/// Raised internally when the text is not a date expression.
priv suberror DateTextError {
  NotADate
}

///|
/// Resolve a date expression into a half-open interval of Unix seconds.
///
/// Supported forms, matched ASCII case-insensitively:
///
/// - `today`, `yesterday`, weekday names (`mon` / `monday`), and month names
///   (`jan` / `january`);
/// - `last` / `inthelast` / `prev` / `previous` followed by a unit
///   (`year`, `month`, `week`, `day`, `hour`, `min`, `sec`), optionally with a
///   count written as digits or as `one` through `ten`, `dozen`, or `hundred`
///   (`lastfiveweeks`); these are rolling windows ending now;
/// - `this` followed by a unit, which selects the current calendar unit;
/// - explicit dates `YYYY[-MM[-DD[THH[:MM[:SS]]]]]`, with an optional space
///   before the time. Two-digit years map below 70 to 2000-2069 and the rest to
///   1900-1999.
///
/// The result is `None` for anything else, including impossible dates such as
/// February 30. Locale-independent parsing is intentional: the query language
/// is English and the calendar is the proleptic Gregorian one.
pub fn resolve_date_span(
  text : StringView,
  now : Int64,
  zone : @time.Zone,
) -> DateSpan? {
  let trimmed = trim_ascii_space("\{text}")
  if trimmed.is_empty() {
    return None
  }
  let lowered = ascii_lower_string(trimmed)
  let resolved = Some(resolve_date_text(lowered, now, zone)) catch { _ => None }
  resolved
}

///|
/// Resolve already-trimmed, already-lowercased date text.
fn resolve_date_text(
  text : String,
  now : Int64,
  zone : @time.Zone,
) -> DateSpan raise {
  if text == "today" {
    return day_span_at(now, 0L, zone)
  }
  if text == "yesterday" {
    return day_span_at(now, -1L, zone)
  }
  match weekday_span(text, now, zone) {
    Some(span) => return span
    None => ()
  }
  match month_name_span(text, now, zone) {
    Some(span) => return span
    None => ()
  }
  match relative_span(text, now, zone) {
    Some(span) => return span
    None => ()
  }
  explicit_span(text, zone)
}

///|
/// The whole day `offset_days` away from the day containing `now`.
fn day_span_at(
  now : Int64,
  offset_days : Int64,
  zone : @time.Zone,
) -> DateSpan raise {
  let current = @time.unix(now, zone~)
  let today = @time.date_time(
    current.year(),
    current.month(),
    current.day(),
    zone~,
  )
  let start = today.add_days(offset_days)
  let end = start.add_days(1L)
  { start: start.to_unix_second(), end: end.to_unix_second(), }
}

///|
/// Map an English weekday name to its Monday-based index (1 through 7).
fn weekday_index(name : String) -> Int32? {
  match name {
    "mon" | "monday" => Some(1)
    "tue" | "tuesday" => Some(2)
    "wed" | "wednesday" => Some(3)
    "thu" | "thursday" => Some(4)
    "fri" | "friday" => Some(5)
    "sat" | "saturday" => Some(6)
    "sun" | "sunday" => Some(7)
    _ => None
  }
}

///|
/// Monday-based value of a `Weekday`.
fn weekday_value(day : @time.Weekday) -> Int32 {
  match day {
    Monday => 1
    Tuesday => 2
    Wednesday => 3
    Thursday => 4
    Friday => 5
    Saturday => 6
    Sunday => 7
  }
}

///|
/// The most recent occurrence of a weekday, including today.
fn weekday_span(
  name : String,
  now : Int64,
  zone : @time.Zone,
) -> DateSpan? raise {
  let target = match weekday_index(name) {
    Some(index) => index
    None => return None
  }
  let current = @time.unix(now, zone~)
  let today = @time.date_time(
    current.year(),
    current.month(),
    current.day(),
    zone~,
  )
  let offset = (weekday_value(today.weekday()) - target + 7) % 7
  let start = today.add_days(-offset.to_int64())
  let end = start.add_days(1L)
  Some({ start: start.to_unix_second(), end: end.to_unix_second(), })
}

///|
/// Map an English month name to its number (1 through 12).
fn month_index(name : String) -> Int32? {
  match name {
    "jan" | "january" => Some(1)
    "feb" | "february" => Some(2)
    "mar" | "march" => Some(3)
    "apr" | "april" => Some(4)
    "may" => Some(5)
    "jun" | "june" => Some(6)
    "jul" | "july" => Some(7)
    "aug" | "august" => Some(8)
    "sep" | "september" => Some(9)
    "oct" | "october" => Some(10)
    "nov" | "november" => Some(11)
    "dec" | "december" => Some(12)
    _ => None
  }
}

///|
/// The most recent occurrence of a month, including the current month.
///
/// `dm:jan` written in March means January of the same year; written in
/// January it means the current January; written in December it means the
/// January of that year. The span is the whole month.
fn month_name_span(
  name : String,
  now : Int64,
  zone : @time.Zone,
) -> DateSpan? raise {
  let month = match month_index(name) {
    Some(index) => index
    None => return None
  }
  let current = @time.unix(now, zone~)
  let mut year = current.year()
  if current.month() < month {
    year = year - 1
  }
  let start = @time.date_time(year, month, 1, zone~)
  let end = start.add_months(1L)
  Some({ start: start.to_unix_second(), end: end.to_unix_second(), })
}

///|
/// A date unit understood by the relative forms.
priv enum DateUnit {
  Year
  Month
  Week
  Day
  Hour
  Minute
  Second
}

///|
/// Parse a unit name. Both the singular and the usual plural forms are
/// accepted; `min` and `sec` follow the upstream shorthand.
fn parse_unit(name : StringView) -> DateUnit? {
  match name {
    "year" | "years" => Some(Year)
    "month" | "months" => Some(Month)
    "week" | "weeks" => Some(Week)
    "day" | "days" => Some(Day)
    "hour" | "hours" => Some(Hour)
    "min" | "mins" | "minute" | "minutes" => Some(Minute)
    "sec" | "secs" | "second" | "seconds" => Some(Second)
    _ => None
  }
}

///|
/// Parse a small count written as digits or as an English number word.
///
/// The upstream list is `one` through `ten`, `dozen`, and `hundred`; digits are
/// accepted as well so `last5weeks` and `lastfiveweeks` mean the same thing.
fn split_count(text : StringView) -> (Int32, StringView)? {
  let mut index = 0
  let mut value = 0
  while index < text.length() {
    let char = match text.get_char(index) {
      Some(char) => char
      None => break
    }
    if char < '0' || char > '9' {
      break
    }
    value = value * 10 + (char.to_int() - '0'.to_int())
    index = index + 1
  }
  if index > 0 {
    return Some((value, text[index:]))
  }
  let words : Array[(String, Int32)] = [
    ("one", 1),
    ("two", 2),
    ("three", 3),
    ("four", 4),
    ("five", 5),
    ("six", 6),
    ("seven", 7),
    ("eight", 8),
    ("nine", 9),
    ("ten", 10),
    ("dozen", 12),
    ("hundred", 100),
  ]
  for pair in words {
    match text.strip_prefix(pair.0) {
      Some(rest) => if !rest.is_empty() { return Some((pair.1, rest)) }
      None => ()
    }
  }
  None
}

///|
/// Parse the `last*`, `previous*`, and `this*` families.
fn relative_span(
  text : String,
  now : Int64,
  zone : @time.Zone,
) -> DateSpan? raise {
  // Longest prefixes first so `inthelast` wins over a hypothetical `in` and
  // `previous` wins over `prev`.
  let prefixes : Array[String] = [
    "inthelast", "previous", "prev", "last", "this",
  ]
  for prefix in prefixes {
    match text.strip_prefix(prefix) {
      Some(rest) => return relative_with(prefix, rest, now, zone)
      None => ()
    }
  }
  None
}

///|
/// Resolve the remainder of a relative expression after its prefix.
fn relative_with(
  prefix : String,
  rest : StringView,
  now : Int64,
  zone : @time.Zone,
) -> DateSpan? raise {
  if prefix == "this" {
    let unit = match parse_unit(rest) {
      Some(unit) => unit
      None => return None
    }
    return Some(current_calendar_span(unit, now, zone))
  }
  match parse_unit(rest) {
    Some(unit) => return Some(rolling_span(unit, 1, now, zone))
    None => ()
  }
  match split_count(rest) {
    Some((count, unit_text)) => {
      if count <= 0 {
        return Some(rolling_span(Second, 1, now, zone))
      }
      match parse_unit(unit_text) {
        Some(unit) => Some(rolling_span(unit, count, now, zone))
        None => None
      }
    }
    None => None
  }
}

///|
/// Rolling interval `[now - count units, now)`.
///
/// Months and years use calendar arithmetic so a "month" on March 31 lands on
/// the last day of February rather than three days into March.
fn rolling_span(
  unit : DateUnit,
  count : Int32,
  now : Int64,
  zone : @time.Zone,
) -> DateSpan raise {
  let current = @time.unix(now, zone~)
  let amount = count.to_int64()
  let start = match unit {
    Year => current.add_years(-amount)
    Month => current.add_months(-amount)
    Week => current.add_weeks(-amount)
    Day => current.add_days(-amount)
    Hour => current.add_hours(-amount)
    Minute => current.add_minutes(-amount)
    Second => current.add_seconds(-amount)
  }
  { start: start.to_unix_second(), end: now, }
}

///|
/// The calendar unit containing `now`, as a half-open interval.
fn current_calendar_span(
  unit : DateUnit,
  now : Int64,
  zone : @time.Zone,
) -> DateSpan raise {
  let current = @time.unix(now, zone~)
  let start = match unit {
    Year => @time.date_time(current.year(), 1, 1, zone~)
    Month => @time.date_time(current.year(), current.month(), 1, zone~)
    Week => {
      let today = @time.date_time(
        current.year(),
        current.month(),
        current.day(),
        zone~,
      )
      let since_monday = weekday_value(today.weekday()) - 1
      today.add_days(-since_monday.to_int64())
    }
    Day =>
      @time.date_time(current.year(), current.month(), current.day(), zone~)
    Hour =>
      @time.date_time(
        current.year(),
        current.month(),
        current.day(),
        hour=current.hour(),
        zone~,
      )
    Minute =>
      @time.date_time(
        current.year(),
        current.month(),
        current.day(),
        hour=current.hour(),
        minute=current.minute(),
        zone~,
      )
    Second =>
      @time.date_time(
        current.year(),
        current.month(),
        current.day(),
        hour=current.hour(),
        minute=current.minute(),
        second=current.second(),
        zone~,
      )
  }
  let end = match unit {
    Year => start.add_years(1L)
    Month => start.add_months(1L)
    Week => start.add_weeks(1L)
    Day => start.add_days(1L)
    Hour => start.add_hours(1L)
    Minute => start.add_minutes(1L)
    Second => start.add_seconds(1L)
  }
  { start: start.to_unix_second(), end: end.to_unix_second(), }
}

///|
/// Parse an explicit calendar date and return the whole unit it names.
fn explicit_span(text : String, zone : @time.Zone) -> DateSpan raise {
  let cursor = DateCursor::new(text)
  let year_start = cursor.pos
  let raw_year = match cursor.read_digits(2, 4) {
    Some(value) => value
    None => raise NotADate
  }
  let year_digits = cursor.pos - year_start
  if year_digits != 2 && year_digits != 4 {
    raise NotADate
  }
  let year = if year_digits == 2 {
    if raw_year < 70 {
      2000 + raw_year
    } else {
      1900 + raw_year
    }
  } else {
    raw_year
  }
  if year < 1 || year > 9999 {
    raise NotADate
  }
  if cursor.eof() {
    return year_span(year, zone)
  }
  if !cursor.consume('-') {
    raise NotADate
  }
  let month = match cursor.read_digits(1, 2) {
    Some(value) => value
    None => raise NotADate
  }
  if month < 1 || month > 12 {
    raise NotADate
  }
  if cursor.eof() {
    return month_span(year, month, zone)
  }
  if !cursor.consume('-') {
    raise NotADate
  }
  let day = match cursor.read_digits(1, 2) {
    Some(value) => value
    None => raise NotADate
  }
  if day < 1 || day > 31 {
    raise NotADate
  }
  if cursor.eof() {
    return day_span(year, month, day, zone)
  }
  if !(cursor.consume(' ') || cursor.consume('t')) {
    raise NotADate
  }
  let hour = match cursor.read_digits(1, 2) {
    Some(value) => value
    None => raise NotADate
  }
  if hour < 0 || hour > 23 {
    raise NotADate
  }
  if cursor.eof() {
    return hour_span(year, month, day, hour, zone)
  }
  if !cursor.consume(':') {
    raise NotADate
  }
  let minute = match cursor.read_digits(1, 2) {
    Some(value) => value
    None => raise NotADate
  }
  if minute < 0 || minute > 59 {
    raise NotADate
  }
  if cursor.eof() {
    return minute_span(year, month, day, hour, minute, zone)
  }
  if !cursor.consume(':') {
    raise NotADate
  }
  let second = match cursor.read_digits(1, 2) {
    Some(value) => value
    None => raise NotADate
  }
  if second < 0 || second > 59 || !cursor.eof() {
    raise NotADate
  }
  second_span(year, month, day, hour, minute, second, zone)
}

///|
/// Whole-year interval.
fn year_span(year : Int32, zone : @time.Zone) -> DateSpan raise {
  let start = @time.date_time(year, 1, 1, zone~)
  let end = start.add_years(1L)
  { start: start.to_unix_second(), end: end.to_unix_second(), }
}

///|
/// Whole-month interval.
fn month_span(year : Int32, month : Int32, zone : @time.Zone) -> DateSpan raise {
  let start = @time.date_time(year, month, 1, zone~)
  let end = start.add_months(1L)
  { start: start.to_unix_second(), end: end.to_unix_second(), }
}

///|
/// Whole-day interval.
fn day_span(
  year : Int32,
  month : Int32,
  day : Int32,
  zone : @time.Zone,
) -> DateSpan raise {
  let start = @time.date_time(year, month, day, zone~)
  let end = start.add_days(1L)
  { start: start.to_unix_second(), end: end.to_unix_second(), }
}

///|
/// One-hour interval starting at the named wall-clock hour.
fn hour_span(
  year : Int32,
  month : Int32,
  day : Int32,
  hour : Int32,
  zone : @time.Zone,
) -> DateSpan raise {
  let start = @time.date_time(year, month, day, hour~, zone~)
  let end = start.add_hours(1L)
  { start: start.to_unix_second(), end: end.to_unix_second(), }
}

///|
/// One-minute interval starting at the named wall-clock minute.
fn minute_span(
  year : Int32,
  month : Int32,
  day : Int32,
  hour : Int32,
  minute : Int32,
  zone : @time.Zone,
) -> DateSpan raise {
  let start = @time.date_time(year, month, day, hour~, minute~, zone~)
  let end = start.add_minutes(1L)
  { start: start.to_unix_second(), end: end.to_unix_second(), }
}

///|
/// One-second interval.
fn second_span(
  year : Int32,
  month : Int32,
  day : Int32,
  hour : Int32,
  minute : Int32,
  second : Int32,
  zone : @time.Zone,
) -> DateSpan raise {
  let start = @time.date_time(year, month, day, hour~, minute~, second~, zone~)
  let end = start.add_seconds(1L)
  { start: start.to_unix_second(), end: end.to_unix_second(), }
}

///|
/// Cursor over ASCII date text.
priv struct DateCursor {
  text : String
  mut pos : Int32
}

///|
fn DateCursor::new(text : String) -> DateCursor {
  { text, pos: 0, }
}

///|
fn DateCursor::eof(self : DateCursor) -> Bool {
  self.pos >= self.text.length()
}

///|
/// Consume `char` if it is next.
fn DateCursor::consume(self : DateCursor, char : Char) -> Bool {
  if self.text.get_char(self.pos) is Some(found) && found == char {
    self.pos = self.pos + 1
    true
  } else {
    false
  }
}

///|
/// Read between `min_len` and `max_len` ASCII digits, stopping at either limit
/// or at the first non-digit.
fn DateCursor::read_digits(
  self : DateCursor,
  min_len : Int32,
  max_len : Int32,
) -> Int32? {
  let mut value = 0
  let mut count = 0
  while count < max_len {
    let digit = match self.text.get_char(self.pos) {
      Some(char) =>
        if char >= '0' && char <= '9' {
          Some(char.to_int() - '0'.to_int())
        } else {
          None
        }
      None => None
    }
    match digit {
      Some(digit) => {
        value = value * 10 + digit
        self.pos = self.pos + 1
        count = count + 1
      }
      None => break
    }
  }
  if count < min_len {
    None
  } else {
    Some(value)
  }
}

///|
/// Trim ASCII whitespace from both ends.
fn trim_ascii_space(text : String) -> String {
  let mut start = 0
  let mut end = text.length()
  while start < end {
    match text.get_char(start) {
      Some(char) =>
        if char.is_ascii_whitespace() {
          start = start + 1
        } else {
          break
        }
      None => break
    }
  }
  while end > start {
    match text.get_char(end - 1) {
      Some(char) =>
        if char.is_ascii_whitespace() {
          end = end - 1
        } else {
          break
        }
      None => break
    }
  }
  text[start:end].to_owned()
}

///|
/// ASCII-lowercase a whole string, leaving non-ASCII characters untouched.
fn ascii_lower_string(text : String) -> String {
  let chars : Array[Char] = []
  for char in text.iter() {
    chars.push(char.to_ascii_lowercase())
  }
  String::from_array(chars)
}
