///|
/// Describe a parsed size comparison, or `none` when it is invalid.
fn size_comparison(text : String) -> String {
  match @query.parse_size_comparison(text) {
    Some(comparison) => comparison.describe()
    None => "none"
  }
}

///|
/// Describe a parsed counting comparison, or `none` when it is invalid.
fn count_comparison(text : String) -> String {
  match @query.parse_count_comparison(text) {
    Some(comparison) => comparison.describe()
    None => "none"
  }
}

///|
/// Describe a parsed date comparison, or `none` when it is invalid.
fn date_comparison(text : String) -> String {
  match @query.parse_date_comparison(text) {
    Some(comparison) => comparison.describe()
    None => "none"
  }
}

///|
test "size suffixes are decimal and case-insensitive" {
  assert_eq(@query.parse_size("0"), Some(0L))
  assert_eq(@query.parse_size("1024"), Some(1024L))
  assert_eq(@query.parse_size("1k"), Some(1000L))
  assert_eq(@query.parse_size("1K"), Some(1000L))
  assert_eq(@query.parse_size("1kb"), Some(1000L))
  assert_eq(@query.parse_size("1KB"), Some(1000L))
  assert_eq(@query.parse_size("2m"), Some(2000000L))
  assert_eq(@query.parse_size("3Mb"), Some(3000000L))
  assert_eq(@query.parse_size("4gb"), Some(4000000000L))
  assert_eq(@query.parse_size("1TB"), Some(1000000000000L))
}

///|
test "malformed sizes are rejected" {
  assert_eq(@query.parse_size(""), None)
  assert_eq(@query.parse_size("kb"), None)
  assert_eq(@query.parse_size("1.5mb"), None)
  assert_eq(@query.parse_size("-1"), None)
  assert_eq(@query.parse_size("1xb"), None)
  assert_eq(@query.parse_size("1kbb"), None)
  assert_eq(@query.parse_size("1 kb"), None)
  assert_eq(@query.parse_size("9223372036854775808"), None)
  assert_eq(@query.parse_size("9000000000000000tb"), None)
}

///|
test "the largest representable size is accepted" {
  assert_eq(
    @query.parse_size("9223372036854775807"),
    Some(9223372036854775807L),
  )
}

///|
test "counts are non-negative integers" {
  assert_eq(@query.parse_count("0"), Some(0L))
  assert_eq(@query.parse_count("12"), Some(12L))
  assert_eq(@query.parse_count("+3"), Some(3L))
  assert_eq(@query.parse_count(""), None)
  assert_eq(@query.parse_count("+"), None)
  assert_eq(@query.parse_count("-1"), None)
  assert_eq(@query.parse_count("1x"), None)
  assert_eq(@query.parse_count("1.0"), None)
  assert_eq(@query.parse_count("9223372036854775808"), None)
}

///|
test "implicit numeric values are exact or half-open ranges" {
  assert_eq(size_comparison("5"), "= 5")
  assert_eq(size_comparison("1kb"), "= 1000")
  assert_eq(size_comparison("1kb..2mb"), ".. 1000 2000000")
  assert_eq(size_comparison("..5"), ".. 0 5")
  assert_eq(size_comparison("5.."), ".. 5 9223372036854775807")
  assert_eq(size_comparison("5..5"), "= 5")
  assert_eq(size_comparison("1..2..3"), "none")
  assert_eq(size_comparison(""), "none")
  assert_eq(size_comparison("kb..mb"), "none")
}

///|
test "counting fields use the same range syntax" {
  assert_eq(count_comparison("3"), "= 3")
  assert_eq(count_comparison("1..5"), ".. 1 5")
  assert_eq(count_comparison("..5"), ".. 0 5")
  assert_eq(count_comparison("5.."), ".. 5 9223372036854775807")
  assert_eq(count_comparison("1..5..9"), "none")
}

///|
test "explicit comparison operators describe their threshold" {
  assert_eq(@query.Comparison::equal(7L).describe(), "= 7")
  assert_eq(
    @query.Comparison::compare(@query.CmpOp::Greater, 10L).describe(),
    "> 10",
  )
  assert_eq(
    @query.Comparison::compare(@query.CmpOp::GreaterEqual, 10L).describe(),
    ">= 10",
  )
  assert_eq(
    @query.Comparison::compare(@query.CmpOp::Smaller, 10L).describe(),
    "< 10",
  )
  assert_eq(
    @query.Comparison::compare(@query.CmpOp::SmallerEqual, 10L).describe(),
    "<= 10",
  )
}

///|
test "date values keep their text for the predicate layer" {
  assert_eq(date_comparison("2024-01"), "= \"2024-01\"")
  assert_eq(date_comparison("2024-01-31 12:00"), "= \"2024-01-31 12:00\"")
  assert_eq(
    date_comparison("lastweek..yesterday"),
    "\"lastweek\" .. \"yesterday\"",
  )
  assert_eq(date_comparison("..yesterday"), ".. \"yesterday\"")
  assert_eq(date_comparison("lastweek.."), "\"lastweek\" ..")
  assert_eq(date_comparison("same..same"), "= \"same\"")
  assert_eq(date_comparison(""), "none")
  assert_eq(date_comparison("a..b..c"), "none")
}

///|
test "date descriptions escape quotes and backslashes" {
  assert_eq(
    @query.DateComparison::new(@query.CmpOp::Equal, lo="a\"b\\c").describe(),
    "= \"a\\\"b\\\\c\"",
  )
}

///|
test "range symbols and comparisons describe themselves" {
  assert_eq(@query.CmpOp::Range.symbol(), "..")
  assert_eq(@query.Comparison::equal(3L).describe(), "= 3")
  assert_eq(@query.Comparison::range(3L, 9L).describe(), ".. 3 9")
  assert_eq(
    @query.Comparison::compare(@query.CmpOp::Range, 5L).describe(),
    ".. 5 5",
  )
}

///|
test "date comparisons describe every open-bound combination" {
  assert_eq(@query.DateComparison::new(@query.CmpOp::Range).describe(), "..")
  assert_eq(
    @query.DateComparison::new(@query.CmpOp::Range, hi="b").describe(),
    ".. \"b\"",
  )
  assert_eq(
    @query.DateComparison::new(@query.CmpOp::Range, lo="a").describe(),
    "\"a\" ..",
  )
  assert_eq(@query.DateComparison::new(@query.CmpOp::Greater).describe(), ">")
  assert_eq(
    @query.DateComparison::new(@query.CmpOp::Greater, lo="a").describe(),
    "> \"a\"",
  )
  assert_eq(date_comparison(".."), "..")
}

///|
test "sizes accept leading zeros and stop at the overflow boundary" {
  assert_eq(@query.parse_size("000"), Some(0L))
  assert_eq(@query.parse_size("007"), Some(7L))
  // 9223372036854775 * 1000 still fits in Int64.
  assert_eq(@query.parse_size("9223372036854775kb"), Some(9223372036854775000L))
  assert_eq(@query.parse_size("9223372036854776kb"), None)
  assert_eq(@query.parse_size("9223372036854775806tb"), None)
  assert_eq(@query.parse_size(" 1"), None)
  assert_eq(@query.parse_size("1 "), None)
}

///|
test "counts accept leading plus and zeros, and reject overflow" {
  assert_eq(@query.parse_count("0003"), Some(3L))
  assert_eq(@query.parse_count("+000"), Some(0L))
  assert_eq(@query.parse_count("++1"), None)
  assert_eq(
    @query.parse_count("9223372036854775807"),
    Some(9223372036854775807L),
  )
  assert_eq(@query.parse_count("9223372036854775808"), None)
  // A leading-zero range collapses to an exact value after parsing.
  assert_eq(count_comparison("1..01"), "= 1")
  assert_eq(size_comparison("1kb..1000"), "= 1000")
}
