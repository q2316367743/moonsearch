///|
/// `moonsearch-bench` measures the query engine without CLI process startup or
/// output formatting. It loads one database, then benchmarks each query with
/// `moonbitlang/core/bench`, which uses a native monotonic clock and
/// microsecond-resolution summaries.
///
/// Output is tab-separated so the Python harness can parse it:
///
/// ```text
/// LOAD    <entries>    <load_us>
/// BENCH   <engine>     <matches>    <summary-json-array>
/// ERROR   <query>      <message>            (stderr)
/// ```
///
/// The summary JSON contains the query name, mean/median/min/max in
/// microseconds, and the batch size chosen by the core benchmark helper.
/// `--count` benchmarks `exec_*_count`; `--first N` benchmarks the canonical
/// order walk that the CLI uses for `--limit N`.
async fn main {
  let argv = @env.args()
  let mut database : String? = None
  let mut engine = "bitmap"
  let mut count_only = false
  let mut first_limit : Int32? = None
  let mut runs : UInt32 = 10
  let queries : Array[String] = []
  let mut index = 1
  while index < argv.length() {
    let arg = argv[index]
    if arg == "-D" || arg == "--database" {
      index = index + 1
      if index >= argv.length() {
        eprintln("error: --database requires a value")
        @env.exit(2)
      }
      database = Some(argv[index])
    } else if arg == "--engine" {
      index = index + 1
      if index >= argv.length() {
        eprintln("error: --engine requires a value")
        @env.exit(2)
      }
      let value = argv[index]
      if value != "scan" && value != "bitmap" {
        eprintln("error: --engine must be scan or bitmap, got '\{value}'")
        @env.exit(2)
      }
      engine = value
    } else if arg == "--count" {
      count_only = true
    } else if arg == "--first" {
      index = index + 1
      if index >= argv.length() {
        eprintln("error: --first requires a value")
        @env.exit(2)
      }
      let parsed = @query.parse_count(argv[index])
      match parsed {
        Some(value) =>
          if value > 0L && value <= 2147483647L {
            first_limit = Some(value.to_int())
          } else {
            eprintln("error: --first must be a positive integer")
            @env.exit(2)
          }
        None => {
          eprintln("error: --first must be a positive integer")
          @env.exit(2)
        }
      }
    } else if arg == "--runs" {
      index = index + 1
      if index >= argv.length() {
        eprintln("error: --runs requires a value")
        @env.exit(2)
      }
      let parsed = @query.parse_count(argv[index])
      match parsed {
        Some(value) =>
          if value > 0L && value <= 2147483647L {
            runs = value.to_int().reinterpret_as_uint()
          } else {
            eprintln("error: --runs must be a positive integer")
            @env.exit(2)
          }
        None => {
          eprintln("error: --runs must be a positive integer")
          @env.exit(2)
        }
      }
    } else if arg == "-h" || arg == "--help" {
      println(
        "Usage: moonsearch-bench --database <PATH> [--engine scan|bitmap] [--count | --first N] [--runs N] <query>...",
      )
      @env.exit(0)
    } else if arg.length() > 0 && arg.get_char(0) is Some('-') {
      eprintln("error: unknown option '\{arg}'")
      @env.exit(2)
    } else {
      queries.push(arg)
    }
    index = index + 1
  }
  let database = match database {
    Some(path) => path
    None => {
      eprintln(
        "Usage: moonsearch-bench --database <PATH> [--engine scan|bitmap] [--count | --first N] [--runs N] <query>...",
      )
      @env.exit(2)
    }
  }
  if queries.is_empty() {
    eprintln("error: at least one query is required")
    @env.exit(2)
  }
  let load_started = @bench.monotonic_clock_start()
  let loaded : Result[@index.Index, String] = try
    @index.Index::read_database(database)
  catch {
    err => Err(err.message())
  } noraise {
    value => Ok(value)
  }
  let load_us = @bench.monotonic_clock_end(load_started)
  let index = match loaded {
    Ok(value) => value
    Err(message) => {
      eprintln("error: \{message}")
      @env.exit(2)
    }
  }
  println("LOAD\t\{index.entry_count()}\t\{load_us}")
  let sink : Array[Int64] = [0L]
  for text in queries {
    let parsed : Result[@query.Query, String] = try @query.parse(text) catch {
      err => Err(err.message())
    } noraise {
      value => Ok(value)
    }
    let query = match parsed {
      Ok(value) => value
      Err(message) => {
        eprintln("ERROR\t\{text}\t\{message}")
        continue
      }
    }
    let run : () -> Unit = if count_only {
      if engine == "scan" {
        () => {
          let count = @exec.exec_count_with(index.store(), query) catch {
            _ => 0
          }
          sink[0] = sink[0] + count.to_int64()
        }
      } else {
        () => {
          let count = @exec.exec_indexed_count(index, query) catch { _ => 0 }
          sink[0] = sink[0] + count.to_int64()
        }
      }
    } else if first_limit is Some(limit) {
      if engine == "scan" {
        () => {
          let hits = @exec.exec_scan_with(
            index.store(),
            query,
            options=@exec.ScanOptions::new(limit~),
          ) catch {
            _ => []
          }
          sink[0] = sink[0] + hits.length().to_int64()
        }
      } else {
        () => {
          let ids = @exec.exec_indexed(index, query) catch {
            _ => @ids.Ids::empty()
          }
          let store = index.store()
          let mut found = 0
          for entry in store.entries_in_order() {
            if found >= limit {
              break
            }
            if ids.contains(store.global_id(entry)) {
              found = found + 1
            }
          }
          sink[0] = sink[0] + found.to_int64()
        }
      }
    } else if engine == "scan" {
      () => {
        let hits = @exec.exec_scan_with(index.store(), query) catch { _ => [] }
        sink[0] = sink[0] + hits.length().to_int64()
      }
    } else {
      () => {
        let ids = @exec.exec_indexed(index, query) catch {
          _ => @ids.Ids::empty()
        }
        sink[0] = sink[0] + ids.cardinality().to_int64()
      }
    }
    let bench = @bench.Bench()
    bench.bench(name=text, run, count=runs)
    let matches = if engine == "scan" {
      @exec.exec_count_with(index.store(), query) catch {
        _ => 0
      }
    } else {
      @exec.exec_indexed_count(index, query) catch {
        _ => 0
      }
    }
    println("BENCH\t\{engine}\t\{matches}\t\{bench.dump_summaries()}")
  }
  // Keep the accumulated cardinalities observable so the optimizer cannot
  // remove the benchmarked calls.
  if sink[0] < 0 {
    eprintln("impossible")
  }
}
