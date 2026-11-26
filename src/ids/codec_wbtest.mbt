///|
test "codec reader ensure uses remaining length without integer overflow" {
  let reader = Reader::new(b"\x00\x00"[:])
  reader.pos = 1
  let outcome = try reader.ensure(2147483647) catch {
    err => Err(err)
  } noraise {
    _ => Ok(())
  }
  assert_true(outcome is Err(IdsError::Truncated))
  reader.ensure(1)
}
