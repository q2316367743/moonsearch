///|
test "platform errors expose their messages" {
  assert_eq(@platform.PlatformError::not_found("gone").message(), "gone")
  assert_eq(@platform.PlatformError::access_denied("nope").message(), "nope")
  assert_eq(@platform.PlatformError::io("boom").message(), "boom")
  assert_eq(
    @platform.PlatformError::not_directory("not a dir").message(),
    "not a dir",
  )
  assert_eq(@platform.PlatformError::unsupported("nope").message(), "nope")
}

///|
test "node and listing constructors keep their fields" {
  let file = @platform.NodeInfo::new(
    name="a.txt",
    kind=@platform.File,
    size=7L,
    mtime=42L,
    device=Some(3UL),
  )
  assert_eq(file.name, "a.txt")
  assert_true(file.kind is @platform.File)
  assert_eq(file.size, 7L)
  assert_eq(file.mtime, 42L)
  assert_eq(file.device, Some(3UL))
  let dir = @platform.NodeInfo::new(name="sub", kind=@platform.Directory)
  assert_eq(dir.size, 0L)
  assert_eq(dir.mtime, 0L)
  assert_eq(dir.device, None)
  let failure = @platform.DirFailure::new(name="gone", message="vanished")
  assert_eq(failure.name, "gone")
  assert_eq(failure.message, "vanished")
  let listing = @platform.DirListing::new(entries=[file], failures=[failure])
  assert_eq(listing.entries.length(), 1)
  assert_eq(listing.failures.length(), 1)
  let empty = @platform.DirListing::new(entries=[])
  assert_eq(empty.failures.length(), 0)
}
