///|
/// Exact stdout from a successful command.
fn config_stdout(result : @cli.CliResult) -> Bytes {
  match result {
    @cli.Success(out) | @cli.SuccessWith(out, _) => out
    @cli.NoMatch(out, _) => out
    @cli.Failure(message) => abort("expected success, got: \{message}")
  }
}

///|
/// Error text from a failed command.
fn config_failure(result : @cli.CliResult) -> String {
  match result {
    @cli.Failure(message) => message
    _ => abort("expected a command failure")
  }
}

///|
/// Remove the process-level final LF for record assertions.
fn config_records(result : @cli.CliResult) -> Bytes {
  let out = config_stdout(result)
  if !out.is_empty() && out[out.length() - 1] == b'\n' {
    out[:out.length() - 1].to_owned()
  } else {
    out
  }
}

///|
/// JSON string literal for a runtime path.
fn config_json_string(value : String) -> String {
  @json.Json::string(value).stringify()
}

///|
/// Create a small source tree used by configuration tests.
async fn config_tree(prefix : String) -> String {
  let dir = @fs.tmpdir(prefix~)
  @fs.write_text("\{dir}/book.epub", "a")
  @fs.write_text("\{dir}/code.rs", "bb")
  @fs.write_text("\{dir}/note.txt", "ccc")
  @fs.write_text("\{dir}/drop.tmp", "x")
  @fs.write_text("\{dir}/.hidden", "h")
  dir
}

///|
/// Write a configuration file under an isolated XDG directory.
async fn write_config(home : String, body : String) -> String {
  let path = "\{home}/config/moonsearch/config.json"
  @fs.mkdir("\{home}/config/moonsearch", recursive=true, allow_existing=true)
  @fs.write_text(path, body)
  path
}

///|
/// Environment that isolates both configuration and database defaults.
fn config_env(home : String) -> Map[String, String] {
  Map([
    ("HOME", home),
    ("XDG_CONFIG_HOME", "\{home}/config"),
    ("XDG_DATA_HOME", "\{home}/data"),
  ])
}

///|
async test "configuration drives index update search count and live scans" {
  let home = @fs.tmpdir(prefix="moonsearch-config-cli")
  let dir = config_tree("moonsearch-config-source")
  let root = @fs.realpath(dir) catch { _ => dir }
  let root_json = config_json_string(root)
  let config_path = write_config(
    home,
    "{\"database\":\"$XDG_DATA_HOME/index.msdb\",\"roots\":[{\"path\":\{root_json}}],\"exclude_hidden\":true,\"excludes\":[{\"pattern\":\"*.tmp\",\"kind\":\"glob\",\"scope\":\"basename\",\"target\":\"files\"}],\"macros\":{\"book\":\"ext:epub;pdf\",\"code\":\"ext:rs;mbt\",\"audio\":\"ext:epub\"},\"search\":{\"sort\":\"size\",\"limit\":1,\"type\":\"file\"},\"engine\":\"bitmap\",\"fast_fields\":[\"size\"],\"one_file_system\":true}",
  )
  let env = config_env(home)
  let indexed = @cli.run(["index", "--config", config_path], env~)
  assert_eq(
    config_records(indexed),
    b"roots: 1\nfolders: 1\nfiles: 3\nbytes: 6\nskipped: 2",
  )
  let database = "\{home}/data/index.msdb"
  assert_true(@fs.exists(database) catch { _ => false })

  let book = @cli.run(["search", "--config", config_path, "book:"], env~)
  let code = @cli.run(["search", "--config", config_path, "code:"], env~)
  let audio = @cli.run(["count", "--config", config_path, "audio:"], env~)
  let defaults = @cli.run(["search", "--config", config_path], env~)
  let overridden = @cli.run(
    ["search", "--config", config_path, "--engine", "scan", "-n", "2"],
    env~,
  )
  let live = @cli.run(
    ["search", "--config", config_path, "--live", "book:"],
    env~,
  )
  assert_eq(config_records(book), @utf8.encode("\{root}/book.epub"))
  assert_eq(config_records(code), @utf8.encode("\{root}/code.rs"))
  assert_eq(config_records(audio), b"1")
  assert_eq(config_records(defaults), @utf8.encode("\{root}/book.epub"))
  let overridden_text = @utf8.decode_lossy(config_records(overridden))
  assert_eq(overridden_text.split("\n").count(), 2)
  assert_eq(config_records(live), @utf8.encode("\{root}/book.epub"))

  @fs.write_text("\{root}/new.epub", "z")
  let updated = @cli.run(["update", "--config", config_path], env~)
  assert_true(config_stdout(updated).length() > 0)
  let epubs = @cli.run(["count", "--config", config_path, "ext:epub"], env~)
  assert_eq(config_records(epubs), b"2")
  @fs.remove(dir, recursive=true)
  @fs.remove(home, recursive=true)
}

///|
async test "explicit CLI roots replace configured roots" {
  let home = @fs.tmpdir(prefix="moonsearch-config-roots")
  let configured = config_tree("moonsearch-config-root-a")
  let explicit = @fs.tmpdir(prefix="moonsearch-config-root-b")
  @fs.write_text("\{explicit}/only.txt", "x")
  let configured_real = @fs.realpath(configured) catch { _ => configured }
  let explicit_real = @fs.realpath(explicit) catch { _ => explicit }
  let config_path = write_config(
    home,
    "{\"database\":\"$XDG_DATA_HOME/index.msdb\",\"roots\":[{\"path\":\{config_json_string(configured_real)}}]}",
  )
  let database = "\{home}/data/index.msdb"
  let indexed = @cli.run(
    ["index", "--config", config_path, "-D", database, "-r", explicit],
    env=config_env(home),
  )
  assert_true(config_stdout(indexed).length() > 0)
  let search = @cli.run(
    ["search", "--config", config_path, "-D", database, "only.txt"],
    env=config_env(home),
  )
  let absent = @cli.run(
    ["search", "--config", config_path, "-D", database, "book.epub"],
    env=config_env(home),
  )
  assert_eq(config_records(search), @utf8.encode("\{explicit_real}/only.txt"))
  assert_eq(absent.exit_code(), 1)
  @fs.remove(configured, recursive=true)
  @fs.remove(explicit, recursive=true)
  @fs.remove(home, recursive=true)
}

///|
async test "update falls back to persisted roots and explicit roots win" {
  let dir = config_tree("moonsearch-update-roots")
  let other = @fs.tmpdir(prefix="moonsearch-update-other")
  @fs.write_text("\{other}/other.txt", "x")
  let database_dir = @fs.tmpdir(prefix="moonsearch-update-db")
  let database = "\{database_dir}/index.msdb"
  let indexed = @cli.run(["index", "--no-config", "-D", database, dir])
  assert_true(config_stdout(indexed).length() > 0)
  @fs.write_text("\{dir}/added.txt", "new")
  let updated = @cli.run(["update", "--no-config", "-D", database])
  assert_true(config_stdout(updated).length() > 0)
  let added = @cli.run(["search", "--no-config", "-D", database, "added.txt"])
  assert_eq(added.exit_code(), 0)

  let replaced = @cli.run(["update", "--no-config", "-D", database, other])
  assert_true(config_stdout(replaced).length() > 0)
  let old = @cli.run(["search", "--no-config", "-D", database, "added.txt"])
  let new = @cli.run(["search", "--no-config", "-D", database, "other.txt"])
  assert_eq(old.exit_code(), 1)
  assert_eq(new.exit_code(), 0)
  @fs.remove(dir, recursive=true)
  @fs.remove(other, recursive=true)
  @fs.remove(database_dir, recursive=true)
}

///|
async test "update reuses persisted excludes and explicit rules replace them" {
  let dir = config_tree("moonsearch-update-excludes")
  let database_dir = @fs.tmpdir(prefix="moonsearch-update-excludes-db")
  let database = "\{database_dir}/index.msdb"
  let indexed = @cli.run([
    "index", "--no-config", "-D", database, "--exclude", "glob:*.tmp", "--exclude-scope",
    "basename", "--exclude-target", "files", dir,
  ])
  assert_true(config_stdout(indexed).length() > 0)
  let persisted = @index.Index::read_database(database) catch {
    err => abort(err.message())
  }
  assert_eq(persisted.excludes().length(), 1)
  assert_eq(persisted.excludes()[0].pattern(), "*.tmp")

  @fs.write_text("\{dir}/new.tmp", "new")
  let updated = @cli.run(["update", "--no-config", "-D", database])
  assert_true(config_stdout(updated).length() > 0)
  assert_eq(
    config_records(
      @cli.run(["count", "--no-config", "-D", database, "ext:tmp"]),
    ),
    b"0",
  )
  assert_eq(
    @cli.run(["search", "--no-config", "-D", database, "note.txt"]).exit_code(),
    0,
  )

  let overridden = @cli.run([
    "update", "--no-config", "-D", database, "--exclude", "glob:*.txt", "--exclude-scope",
    "basename", "--exclude-target", "files",
  ])
  assert_true(config_stdout(overridden).length() > 0)
  assert_eq(
    config_records(
      @cli.run(["count", "--no-config", "-D", database, "ext:tmp"]),
    ),
    b"2",
  )
  let replaced = @index.Index::read_database(database) catch {
    err => abort(err.message())
  }
  assert_eq(replaced.excludes()[0].pattern(), "*.txt")

  let home = @fs.tmpdir(prefix="moonsearch-update-excludes-config")
  let config_path = write_config(
    home,
    "{\"database\":\{config_json_string(database)},\"excludes\":[{\"pattern\":\"*.epub\",\"kind\":\"glob\",\"scope\":\"basename\",\"target\":\"files\"}]}",
  )
  let configured = @cli.run(
    ["update", "--config", config_path],
    env=config_env(home),
  )
  assert_true(config_stdout(configured).length() > 0)
  assert_eq(
    config_records(
      @cli.run(["count", "--no-config", "-D", database, "ext:epub"]),
    ),
    b"0",
  )
  assert_eq(
    config_records(
      @cli.run(["count", "--no-config", "-D", database, "ext:tmp"]),
    ),
    b"2",
  )
  @fs.remove(dir, recursive=true)
  @fs.remove(database_dir, recursive=true)
  @fs.remove(home, recursive=true)
}

///|
async test "no-config skips invalid defaults and explicit missing files" {
  let home = @fs.tmpdir(prefix="moonsearch-no-config")
  let dir = config_tree("moonsearch-no-config-source")
  ignore(write_config(home, "{\"bogus\":true}"))
  let missing = "\{home}/missing.json"
  let database = "\{home}/data/no-config.msdb"
  let env = config_env(home)
  let skipped = @cli.run(
    ["index", "--no-config", "--config", missing, "-D", database, dir],
    env~,
  )
  assert_true(config_stdout(skipped).length() > 0)
  let explicit = @cli.run(
    ["index", "--config", missing, "-D", database, dir],
    env~,
  )
  assert_eq(explicit.exit_code(), 2)
  assert_true(config_failure(explicit).contains("cannot read configuration"))
  let invalid_default = @cli.run(["index", "-D", database, dir], env~)
  assert_eq(invalid_default.exit_code(), 2)
  assert_true(config_failure(invalid_default).contains("unknown field 'bogus'"))
  let empty_config_env = Map([
    ("HOME", home),
    ("XDG_CONFIG_HOME", "\{home}/config"),
    ("XDG_DATA_HOME", "\{home}/data"),
    ("MOONSEARCH_CONFIG", ""),
  ])
  let empty_config = @cli.run(
    ["index", "-D", database, dir],
    env=empty_config_env,
  )
  assert_eq(empty_config.exit_code(), 2)
  assert_true(config_failure(empty_config).contains("unknown field 'bogus'"))

  let selected = "\{home}/selected.json"
  let root = @fs.realpath(dir) catch { _ => dir }
  @fs.write_text(
    selected,
    "{\"database\":\"$XDG_DATA_HOME/selected.msdb\",\"roots\":[{\"path\":\{config_json_string(root)}}]}",
  )
  let selected_env = Map([
    ("HOME", home),
    ("XDG_CONFIG_HOME", "\{home}/config"),
    ("XDG_DATA_HOME", "\{home}/data"),
    ("MOONSEARCH_CONFIG", selected),
    ("MOONSEARCH_DATABASE", ""),
  ])
  let from_environment = @cli.run(["index"], env=selected_env)
  assert_true(config_stdout(from_environment).length() > 0)
  assert_true(@fs.exists("\{home}/data/selected.msdb") catch { _ => false })
  @fs.remove(dir, recursive=true)
  @fs.remove(home, recursive=true)
}

///|
async test "CLI environment and config database precedence is stable" {
  let home = @fs.tmpdir(prefix="moonsearch-config-precedence")
  let dir = config_tree("moonsearch-config-precedence-source")
  let root = @fs.realpath(dir) catch { _ => dir }
  let config_path = write_config(
    home,
    "{\"database\":\"$XDG_DATA_HOME/config.msdb\",\"roots\":[{\"path\":\{config_json_string(root)}}]}",
  )
  let with_env = Map([
    ("HOME", home),
    ("XDG_CONFIG_HOME", "\{home}/config"),
    ("XDG_DATA_HOME", "\{home}/data"),
    ("MOONSEARCH_DATABASE", "\{home}/data/env.msdb"),
  ])
  let from_env = @cli.run(["index", "--config", config_path], env=with_env)
  assert_true(config_stdout(from_env).length() > 0)
  assert_true(@fs.exists("\{home}/data/env.msdb") catch { _ => false })
  assert_false(@fs.exists("\{home}/data/config.msdb") catch { _ => false })
  let cli_database = "\{home}/data/cli.msdb"
  let from_cli = @cli.run(
    ["index", "--config", config_path, "-D", cli_database],
    env=with_env,
  )
  assert_true(config_stdout(from_cli).length() > 0)
  assert_true(@fs.exists(cli_database) catch { _ => false })
  @fs.remove(dir, recursive=true)
  @fs.remove(home, recursive=true)
}

///|
async test "configured macro cycles are reported when expanded" {
  let home = @fs.tmpdir(prefix="moonsearch-config-cycle")
  let dir = config_tree("moonsearch-config-cycle-source")
  let root = @fs.realpath(dir) catch { _ => dir }
  let config_path = write_config(
    home,
    "{\"roots\":[{\"path\":\{config_json_string(root)}}],\"macros\":{\"a\":\"b:\",\"b\":\"a:\"}}",
  )
  let result = @cli.run(
    ["search", "--config", config_path, "--live", "a:"],
    env=config_env(home),
  )
  assert_eq(result.exit_code(), 2)
  let message = config_failure(result)
  if !message.contains("expands to itself") {
    abort(message)
  }
  @fs.remove(dir, recursive=true)
  @fs.remove(home, recursive=true)
}

///|
async test "configured unreadable directory policy can be overridden" {
  let home = @fs.tmpdir(prefix="moonsearch-config-unreadable")
  let dir = @fs.tmpdir(prefix="moonsearch-config-unreadable-source")
  let locked = "\{dir}/locked"
  @fs.mkdir(locked)
  @fs.write_text("\{locked}/secret", "x")
  @fs.write_text("\{dir}/open.txt", "ok")
  @fs.chmod(locked, 0o000)
  let denied = !(@fs.can_read(locked) catch { _ => false })
  let root = @fs.realpath(dir) catch { _ => dir }
  let config_path = write_config(
    home,
    "{\"roots\":[{\"path\":\{config_json_string(root)}}],\"unreadable_directories\":\"fatal\"}",
  )
  let env = config_env(home)
  let fatal = @cli.run(
    ["index", "--config", config_path, "-D", "\{home}/data/fatal.msdb"],
    env~,
  )
  let continued = @cli.run(
    [
      "index",
      "--config",
      config_path,
      "-D",
      "\{home}/data/continue.msdb",
      "--unreadable-directories",
      "continue",
    ],
    env~,
  )
  @fs.chmod(locked, 0o755)
  if denied {
    assert_eq(fatal.exit_code(), 2)
    let message = config_failure(fatal)
    if !message.contains("not readable") {
      abort(message)
    }
    assert_true(config_stdout(continued).length() > 0)
  } else {
    assert_true(config_stdout(fatal).length() > 0)
    assert_true(config_stdout(continued).length() > 0)
  }
  @fs.remove(dir, recursive=true)
  @fs.remove(home, recursive=true)
}
