///|
/// Global options accepted before or after the subcommand.
fn global_options() -> Array[@argparse.OptionArg] {
  [
    @argparse.OptionArg(
      "database",
      short='D',
      about="Path to the index database",
      env="MOONSEARCH_DATABASE",
      global=true,
    ),
    @argparse.OptionArg(
      "config",
      about="Path to the configuration file",
      env="MOONSEARCH_CONFIG",
      global=true,
    ),
  ]
}

///|
/// Global flags accepted before or after the subcommand.
fn global_flags() -> Array[@argparse.FlagArg] {
  [
    @argparse.FlagArg(
      "no-config",
      about="Do not read the configuration file",
      global=true,
    ),
    @argparse.FlagArg(
      "verbose",
      short='v',
      about="Print detailed progress information",
      action=Count,
      global=true,
    ),
    @argparse.FlagArg(
      "quiet",
      short='q',
      about="Only print results and errors",
      global=true,
    ),
    @argparse.FlagArg(
      "stats",
      about="Print timings and index sizes to stderr",
      global=true,
    ),
    @argparse.FlagArg(
      "explain",
      about="Print the execution plan to stderr",
      global=true,
    ),
  ]
}

///|
/// The `query` positional shared by `search` and `count`.
fn query_positionals() -> Array[@argparse.PositionArg] {
  [
    @argparse.PositionArg(
      "query",
      about="Search query; bare terms are joined with single spaces",
      num_args=@argparse.ValueRange(lower=0),
    ),
  ]
}

///|
/// Filters shared by `search` and `count`.
fn filter_options() -> Array[@argparse.OptionArg] {
  [
    @argparse.OptionArg(
      "type",
      about="Restrict the result kind: any, file, or folder",
      default_values=["any"],
    ),
    @argparse.OptionArg("engine", about="Execution engine: scan or bitmap", default_values=[
      "scan",
    ]),
    @argparse.OptionArg(
      "root",
      about="Root directory for a live scan; may be repeated",
      action=Append,
    ),
  ]
}

///|
/// Flags shared by `search` and `count`.
fn filter_flags() -> Array[@argparse.FlagArg] {
  [
    @argparse.FlagArg(
      "case-sensitive",
      short='c',
      about="Match the query case-sensitively",
    ),
    @argparse.FlagArg(
      "exact",
      short='e',
      about="Match whole names instead of substrings",
    ),
    @argparse.FlagArg(
      "search-path",
      short='p',
      about="Match against full paths instead of names",
    ),
    @argparse.FlagArg(
      "regex",
      short='r',
      about="Treat the whole query as a regular expression",
    ),
    @argparse.FlagArg(
      "live",
      about="Scan the configured roots instead of reading the index",
    ),
    @argparse.FlagArg(
      "auto-index",
      about="Build the index first when the database is missing",
    ),
    @argparse.FlagArg("compat", about="Reproduce upstream query error recovery"),
  ]
}

///|
/// Search-only output options.
fn output_options() -> Array[@argparse.OptionArg] {
  [
    @argparse.OptionArg(
      "sort",
      about="Result order: name, path, size, mtime, ext, or type",
      default_values=["name"],
    ),
    @argparse.OptionArg(
      "limit",
      short='n',
      about="Maximum number of results; 0 means unlimited",
      default_values=["0"],
    ),
    @argparse.OptionArg("format", about="Custom output template for each match"),
    @argparse.OptionArg(
      "relative-to",
      about="Print paths relative to this directory",
    ),
  ]
}

///|
/// Search-only output flags.
fn output_flags() -> Array[@argparse.FlagArg] {
  [
    @argparse.FlagArg("reverse", about="Reverse the result order"),
    @argparse.FlagArg("folders-first", about="Print folders before files"),
    @argparse.FlagArg(
      "null",
      short='0',
      about="Terminate every result with NUL instead of a newline",
    ),
    @argparse.FlagArg("json", about="Print one JSON object per result"),
    @argparse.FlagArg("basename", about="Print only the entry name"),
  ]
}

///|
/// Options shared by `index` and `update`.
fn scan_options() -> Array[@argparse.OptionArg] {
  [
    @argparse.OptionArg(
      "root",
      short='r',
      about="Root directory to index; may be repeated",
      action=Append,
    ),
    @argparse.OptionArg(
      "exclude",
      short='x',
      about="Exclude pattern; may be repeated",
      action=Append,
    ),
    @argparse.OptionArg(
      "exclude-scope",
      about="Pattern scope: full_path or basename",
      default_values=["full_path"],
    ),
    @argparse.OptionArg(
      "exclude-target",
      about="Pattern target: both, files, or folders",
      default_values=["both"],
    ),
    @argparse.OptionArg(
      "fast-fields",
      about="Range fields loaded eagerly: size,mtime",
      default_values=["size,mtime"],
    ),
  ]
}

///|
/// Flags shared by `index` and `update`.
fn scan_flags() -> Array[@argparse.FlagArg] {
  [
    @argparse.FlagArg(
      "exclude-hidden",
      about="Skip names that start with a dot",
    ),
    @argparse.FlagArg(
      "one-file-system",
      about="Do not cross file system boundaries",
    ),
    @argparse.FlagArg(
      "no-default-excludes",
      about="Do not skip /proc, /sys, /dev, and /run",
    ),
    @argparse.FlagArg(
      "allow-nested-roots",
      about="Allow roots that are nested inside each other",
    ),
    @argparse.FlagArg("no-trigram", about="Do not build the trigram index"),
  ]
}

///|
/// Root arguments shared by `index` and `update`.
///
/// `-r/--root` and bare positionals are both accepted. Repeated `-r` values are
/// collected first, then bare positionals, and that order is preserved in
/// `RootInfo`.
fn root_positionals() -> Array[@argparse.PositionArg] {
  [
    @argparse.PositionArg(
      "roots",
      about="Root directories to index; may be repeated",
      num_args=@argparse.ValueRange(lower=0),
    ),
  ]
}

///|
/// Build an `index` or `update` command.
fn scan_command(name : String, about : String) -> @argparse.Command {
  @argparse.Command(
    name,
    about~,
    version=@core.VERSION_TEXT,
    options=scan_options(),
    flags=scan_flags(),
    positionals=root_positionals(),
  )
}

///|
/// Build the `search` subcommand.
fn search_command() -> @argparse.Command {
  @argparse.Command(
    "search",
    about="Search the index",
    version=@core.VERSION_TEXT,
    options=filter_options() + output_options(),
    flags=filter_flags() + output_flags(),
    positionals=query_positionals(),
  )
}

///|
/// Build the `count` subcommand.
fn count_command() -> @argparse.Command {
  @argparse.Command(
    "count",
    about="Print the number of matches",
    version=@core.VERSION_TEXT,
    options=filter_options(),
    flags=filter_flags(),
    positionals=query_positionals(),
  )
}

///|
/// Build the `info` subcommand.
fn info_command() -> @argparse.Command {
  @argparse.Command(
    "info",
    about="Show index statistics",
    version=@core.VERSION_TEXT,
  )
}

///|
/// Build the complete `moonsearch` command specification.
///
/// `search` is the default subcommand, so `moonsearch 'report pdf'` is
/// equivalent to `moonsearch search 'report pdf'`.
pub fn build_command() -> @argparse.Command {
  @argparse.Command(
    "moonsearch",
    about="Fast file search over a persistent inverted index",
    version=@core.VERSION_TEXT,
    options=global_options(),
    flags=global_flags(),
    subcommands=[
      scan_command("index", "Scan the configured roots and write the index"),
      scan_command(
        "update", "Rescan the configured roots and rebuild the index",
      ),
      search_command(),
      count_command(),
      info_command(),
    ],
    default_subcommand="search",
  )
}
