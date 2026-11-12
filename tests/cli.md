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
error: the index is not persisted yet (S12); pass --live --root <PATH> to scan roots for this query
[2]
$ moonx q2316367743/moonsearch/cmd/moonsearch index --help
Usage: moonsearch index [options] [roots...]

Scan the configured roots and write the index

Arguments:
  roots...  Root directories to index; may be repeated

Options:
  -h, --help                         Show help information.
  -V, --version                      Show version information.
  --no-config                        Do not read the configuration file
  -v, --verbose                      Print detailed progress information
  -q, --quiet                        Only print results and errors
  --stats                            Print timings and index sizes to stderr
  --explain                          Print the execution plan to stderr
  -D, --database <database>          Path to the index database [env: MOONSEARCH_DATABASE]
  --config <config>                  Path to the configuration file [env: MOONSEARCH_CONFIG]
  --exclude-hidden                   Skip names that start with a dot
  --one-file-system                  Do not cross file system boundaries
  --no-default-excludes              Do not skip /proc, /sys, /dev, and /run
  --allow-nested-roots               Allow roots that are nested inside each other
  --no-trigram                       Do not build the trigram index
  -r, --root <root>                  Root directory to index; may be repeated
  -x, --exclude <exclude>            Exclude pattern; may be repeated
  --exclude-scope <exclude-scope>    Pattern scope: full_path or basename [default: full_path]
  --exclude-target <exclude-target>  Pattern target: both, files, or folders [default: both]
  --fast-fields <fast-fields>        Range fields loaded eagerly: size,mtime [default: size,mtime]

$ moonx q2316367743/moonsearch/cmd/moonsearch update --help
Usage: moonsearch update [options] [roots...]

Rescan the configured roots and rebuild the index

Arguments:
  roots...  Root directories to index; may be repeated

Options:
  -h, --help                         Show help information.
  -V, --version                      Show version information.
  --no-config                        Do not read the configuration file
  -v, --verbose                      Print detailed progress information
  -q, --quiet                        Only print results and errors
  --stats                            Print timings and index sizes to stderr
  --explain                          Print the execution plan to stderr
  -D, --database <database>          Path to the index database [env: MOONSEARCH_DATABASE]
  --config <config>                  Path to the configuration file [env: MOONSEARCH_CONFIG]
  --exclude-hidden                   Skip names that start with a dot
  --one-file-system                  Do not cross file system boundaries
  --no-default-excludes              Do not skip /proc, /sys, /dev, and /run
  --allow-nested-roots               Allow roots that are nested inside each other
  --no-trigram                       Do not build the trigram index
  -r, --root <root>                  Root directory to index; may be repeated
  -x, --exclude <exclude>            Exclude pattern; may be repeated
  --exclude-scope <exclude-scope>    Pattern scope: full_path or basename [default: full_path]
  --exclude-target <exclude-target>  Pattern target: both, files, or folders [default: both]
  --fast-fields <fast-fields>        Range fields loaded eagerly: size,mtime [default: size,mtime]

$ moonx q2316367743/moonsearch/cmd/moonsearch index
@STDOUT (empty)
@STDERR
error: no roots configured; pass --root <PATH> or a root argument
[2]

$ moonx q2316367743/moonsearch/cmd/moonsearch count 'ext:mp4'
@STDOUT (empty)
@STDERR
error: the index is not persisted yet (S12); pass --live --root <PATH> to scan roots for this query
[2]
```

End-to-end indexing against the committed fixture tree:

```mooncram q2316367743/moonsearch
$ moonx q2316367743/moonsearch/cmd/moonsearch index fixture
roots: 1
folders: 2
files: 3
bytes: 12

$ moonx q2316367743/moonsearch/cmd/moonsearch index --exclude-hidden -x '*.pdf' --exclude-scope basename fixture
roots: 1
folders: 2
files: 1
bytes: 5
skipped: 2

$ moonx q2316367743/moonsearch/cmd/moonsearch index --quiet fixture
@STDOUT (empty)
@STDERR (empty)

$ moonx q2316367743/moonsearch/cmd/moonsearch index --bogus fixture
@STDOUT (empty)
@STDERR (ignore)
[2]
```

The scan engine reads the same fixture through `--live`, so no database is
needed:

```mooncram q2316367743/moonsearch
$ moonx q2316367743/moonsearch/cmd/moonsearch search --live --root fixture a.txt
*/fixture/a.txt (glob)

$ moonx q2316367743/moonsearch/cmd/moonsearch search --live --root fixture ext:pdf
*/fixture/sub/b.pdf (glob)

$ moonx q2316367743/moonsearch/cmd/moonsearch search --live --root fixture folder:
*/fixture (glob)
*/fixture/sub (glob)

$ moonx q2316367743/moonsearch/cmd/moonsearch search --live --root fixture -n 1
*/fixture (glob)

$ moonx q2316367743/moonsearch/cmd/moonsearch count --live --root fixture ext:pdf
1

$ moonx q2316367743/moonsearch/cmd/moonsearch count --live --root fixture ext:mp4
0
[1]

$ moonx q2316367743/moonsearch/cmd/moonsearch search --live --root fixture ext:mp4
@STDOUT (empty)
@STDERR (empty)
[1]

$ moonx q2316367743/moonsearch/cmd/moonsearch search --live --root fixture --engine bitmap x
@STDOUT (empty)
@STDERR
error: the bitmap engine is not implemented yet; pass --engine scan
[2]
```
