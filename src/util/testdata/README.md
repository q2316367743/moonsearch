# Time zone test data

`America-New_York.tzif` is an unmodified copy of the IANA tz database file
`/usr/share/zoneinfo/America/New_York` (tz database, public domain). It exists
so the DST tests do not depend on the host's zoneinfo installation and produce
the same 23/25-hour day and gap/overlap expectations on Linux, macOS, and CI.

The test target reads it through the embedded byte array in
`src/util/dst_fixture_test.mbt`. After replacing the fixture, regenerate that
file from the repository root:

```sh
moon tool embed --binary \
  --input src/util/testdata/America-New_York.tzif \
  --output src/util/dst_fixture_test.mbt \
  --name new_york_tzif
```

The assertions in `src/util/time_test.mbt` name the exact UTC instants they
expect, so a tz database update that changes 2024 history is visible as a
failure rather than silently changing the tested behavior.
