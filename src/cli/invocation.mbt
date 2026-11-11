///|
/// The subcommand selected by the command line.
pub(all) enum Command {
  Index
  Update
  Search
  Count
  Info
}

///|
/// Canonical name of the subcommand, as typed by the user.
pub fn Command::name(self : Command) -> String {
  match self {
    Index => "index"
    Update => "update"
    Search => "search"
    Count => "count"
    Info => "info"
  }
}

///|
/// A fully parsed command line.
///
/// `matches` keeps the raw argparse result so later steps can read the
/// subcommand-specific options without changing this type.
pub(all) struct Invocation {
  command : Command
  query : String
  matches : @argparse.Matches
}

///|
/// Result of parsing a command line, before any command runs.
pub(all) enum Parsed {
  Run(Invocation)
  ShowHelp(String)
  ShowVersion(String)
}

///|
/// Read the `query` positional as a single space-joined string.
fn query_of(matches : @argparse.Matches) -> String {
  match matches.values.get("query") {
    Some(values) => values.join(" ")
    None => ""
  }
}

///|
fn make_invocation(
  command : Command,
  matches : @argparse.Matches,
) -> Invocation {
  { command, query: query_of(matches), matches, }
}

///|
/// Map the argparse result to an `Invocation`.
///
/// `default_subcommand="search"` means a parse result without a subcommand is
/// still a search invocation.
fn invocation_of(matches : @argparse.Matches) -> Invocation {
  match matches.subcommand {
    Some(("index", sub)) => make_invocation(Index, sub)
    Some(("update", sub)) => make_invocation(Update, sub)
    Some(("search", sub)) => make_invocation(Search, sub)
    Some(("count", sub)) => make_invocation(Count, sub)
    Some(("info", sub)) => make_invocation(Info, sub)
    _ => make_invocation(Search, matches)
  }
}

///|
/// Parse a command line without touching the process environment.
///
/// `argv` excludes the program name. Help and version requests are returned as
/// values instead of exiting, which keeps them testable.
pub fn parse(
  argv : ArrayView[String],
  env~ : Map[String, String] = Map([]),
) -> Result[Parsed, String] {
  let command = build_command()
  if argv.length() == 0 {
    return match command.parse_outcome(argv=["--help"], env~) {
      @argparse.Help(text) => Ok(ShowHelp(text))
      _ => Ok(ShowHelp(command.render_help()))
    }
  }
  match command.parse_outcome(argv~, env~) {
    @argparse.Parsed(matches) => Ok(Run(invocation_of(matches)))
    @argparse.Help(text) => Ok(ShowHelp(text))
    @argparse.Version(text) => Ok(ShowVersion(text))
    @argparse.Failed(error) => Err(error.to_string())
  }
}
