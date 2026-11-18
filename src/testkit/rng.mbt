///|
/// Deterministic pseudo-random generator for property and differential tests.
///
/// The generator is a xorshift64* variant: it depends only on `UInt64`
/// arithmetic, so the same seed produces the same sequence on every platform
/// and every run. Tests never use the system clock or an entropy source, which
/// makes a failing seed reproducible from the test name alone.
///
/// It is deliberately small and not cryptographic. Its only job is to drive
/// quickcheck-style inputs and fixture trees.
pub struct Rng {
  mut state : UInt64
}

///|
/// Create a generator. Zero is not a valid xorshift state, so it is replaced
/// by the golden-ratio constant.
pub fn Rng::new(seed : UInt64) -> Rng {
  { state: if seed == 0UL { 0x9E3779B97F4A7C15UL } else { seed }, }
}

///|
/// Advance the generator and return the next 64-bit value.
fn Rng::next(self : Rng) -> UInt64 {
  let mut value = self.state
  value = value ^ (value << 13)
  value = value ^ (value >> 7)
  value = value ^ (value << 17)
  self.state = value
  value
}

///|
/// Uniform-ish integer in `[0, bound)`.
///
/// `bound <= 0` returns zero so callers never have to guard the empty-array
/// case. The high bit is dropped before the modulo, keeping the value
/// non-negative without an unsigned-to-signed conversion.
pub fn Rng::below(self : Rng, bound : Int32) -> Int32 {
  if bound <= 0 {
    return 0
  }
  let value = (self.next() >> 1).reinterpret_as_int64() % bound.to_int64()
  value.to_int()
}

///|
/// Integer in `[low, high]`, both ends included.
pub fn Rng::between(self : Rng, low : Int32, high : Int32) -> Int32 {
  if high <= low {
    return low
  }
  low + self.below(high - low + 1)
}

///|
/// True with the given percentage probability.
pub fn Rng::chance(self : Rng, percent : Int32) -> Bool {
  self.below(100) < percent
}

///|
/// Pick one element of a non-empty array.
pub fn Rng::pick(self : Rng, values : Array[String]) -> String {
  values[self.below(values.length())]
}
