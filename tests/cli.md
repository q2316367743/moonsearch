# moonsearch CLI contract

End-to-end checks for the S01 CLI surface. Unit tests in `src/cli` cover the
same help text in-process; this document verifies the real executable's stdout,
stderr, and exit codes.

```mooncram q2316367743/moonsearch
$ moonx q2316367743/moonsearch/cmd/moonsearch --version
moonsearch 0.1.0

$ moonx q2316367743/moonsearch/cmd/moonsearch --help
Usage: moonsearch [options] [command]

Fast file search over a persistent inverted index

Commands:
  index   Scan the configured roots and write the index
  update  Rescan the configured roots and rebuild the index
  search  Search the index (default)
  count   Print the number of matches
  info    Show index statistics
  help    Print help for the subcommand(s).

Options:
  -h, --help                 Show help information.
  -V, --version              Show version information.
  --no-config                Do not read the configuration file
  -v, --verbose              Print detailed progress information
  -q, --quiet                Only print results and errors
  --stats                    Print timings and index sizes to stderr
  --explain                  Print the execution plan to stderr
  -D, --database <database>  Path to the index database [env: MOONSEARCH_DATABASE]
  --config <config>          Path to the configuration file [env: MOONSEARCH_CONFIG]

$ moonx q2316367743/moonsearch/cmd/moonsearch search --bogus
@STDOUT (empty)
@STDERR (ignore)
[2]

$ moonx q2316367743/moonsearch/cmd/moonsearch 'ext:pdf'
@STDOUT (empty)
@STDERR
error: 'search' is not implemented yet
[2]
```
