///|
/// A million-id sorted operand and a tiny, widely spaced operand. The short
/// side is the shape for which the plan selects galloping.
fn ids_skew_fixture() -> (Array[Int32], Array[Int32]) {
  let long : Array[Int32] = []
  for index in 0..<1_000_000 {
    long.push(index * 17)
  }
  let short : Array[Int32] = []
  for index in 0..<32 {
    short.push(index * 500_003)
  }
  (long, short)
}

///|
test "bench skewed sorted intersection merge" (it : @bench.T) {
  let (long, short) = ids_skew_fixture()
  it.bench(fn() {
    let result : Array[Int32] = []
    sorted_intersect_merge(short, long, result)
    it.keep(result.length())
  })
}

///|
test "bench skewed sorted intersection gallop" (it : @bench.T) {
  let (long, short) = ids_skew_fixture()
  it.bench(fn() {
    let result : Array[Int32] = []
    gallop_intersect(short, long, result)
    it.keep(result.length())
  })
}

///|
test "bench skewed sorted difference merge" (it : @bench.T) {
  let (long, short) = ids_skew_fixture()
  it.bench(fn() {
    let result : Array[Int32] = []
    sorted_difference_merge(short, long, result)
    it.keep(result.length())
  })
}

///|
test "bench skewed sorted difference gallop" (it : @bench.T) {
  let (long, short) = ids_skew_fixture()
  it.bench(fn() {
    let result : Array[Int32] = []
    gallop_difference(short, long, result)
    it.keep(result.length())
  })
}
