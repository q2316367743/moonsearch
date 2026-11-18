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

$ moonx q2316367743/moonsearch/cmd/moonsearch -D _build/cram-missing.msdb 'ext:pdf'
@STDOUT (empty)
@STDERR
error: no index database at _build/cram-missing.msdb; run 'moonsearch index <ROOT>' to create it
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

$ moonx q2316367743/moonsearch/cmd/moonsearch count -D _build/cram-missing.msdb 'ext:mp4'
@STDOUT (empty)
@STDERR
error: no index database at _build/cram-missing.msdb; run 'moonsearch index <ROOT>' to create it
[2]
```

End-to-end indexing against the committed fixture tree:

```mooncram q2316367743/moonsearch
$ moonx q2316367743/moonsearch/cmd/moonsearch index -D _build/cram/index.msdb fixture
roots: 1
folders: 2
files: 3
bytes: 12

$ moonx q2316367743/moonsearch/cmd/moonsearch index -D _build/cram/index.msdb --exclude-hidden -x '*.pdf' --exclude-scope basename fixture
roots: 1
folders: 2
files: 1
bytes: 5
skipped: 2

$ moonx q2316367743/moonsearch/cmd/moonsearch index -D _build/cram/index.msdb --quiet fixture
@STDOUT (empty)
@STDERR (empty)

$ moonx q2316367743/moonsearch/cmd/moonsearch index --bogus fixture
@STDOUT (empty)
@STDERR (ignore)
[2]
```

A plain `info` and `search` read the database that `index` wrote; the search
still works after the fixture tree is no longer relevant because the index is
persisted:

```mooncram q2316367743/moonsearch
$ moonx q2316367743/moonsearch/cmd/moonsearch info -D _build/cram/index.msdb --verify
database: _build/cram/index.msdb
format: MSDB 2.0
built: [0-9]+ (regex)
roots: 1
folders: 2
files: 3
names: 5
size: [0-9]+ bytes (regex)
trigram: [0-9]+ keys (regex)
checksum: verified
sections: [a-z]+=[0-9]+( [a-z]+=[0-9]+)* (regex)

$ moonx q2316367743/moonsearch/cmd/moonsearch search -D _build/cram/index.msdb a.txt
*/fixture/a.txt (glob)

$ moonx q2316367743/moonsearch/cmd/moonsearch search -D _build/cram/index.msdb --engine bitmap ext:pdf
*/fixture/sub/b.pdf (glob)

$ moonx q2316367743/moonsearch/cmd/moonsearch count -D _build/cram/index.msdb ext:pdf
1
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

$ moonx q2316367743/moonsearch/cmd/moonsearch search --live --root fixture --engine bitmap a.txt
*/fixture/a.txt (glob)

$ moonx q2316367743/moonsearch/cmd/moonsearch search --live --root fixture --engine bitmap ext:pdf
*/fixture/sub/b.pdf (glob)

$ moonx q2316367743/moonsearch/cmd/moonsearch count --live --root fixture --engine bitmap ext:pdf
1

$ moonx q2316367743/moonsearch/cmd/moonsearch search --live --root fixture --engine bitmap ext:mp4
@STDOUT (empty)
@STDERR (empty)
[1]
```

Result ordering and output formats (S11). Sizes in the fixture are
`sub/b.pdf` = 1 B, `a.txt` = 5 B, and `.hidden` = 6 B:

```mooncram q2316367743/moonsearch
$ moonx q2316367743/moonsearch/cmd/moonsearch search --live --root fixture --type file --sort size
*/fixture/sub/b.pdf (glob)
*/fixture/a.txt (glob)
*/fixture/.hidden (glob)

$ moonx q2316367743/moonsearch/cmd/moonsearch search --live --root fixture --type file --sort size --reverse
*/fixture/.hidden (glob)
*/fixture/a.txt (glob)
*/fixture/sub/b.pdf (glob)

$ moonx q2316367743/moonsearch/cmd/moonsearch search --live --root fixture --type file --sort ext
*/fixture/.hidden (glob)
*/fixture/sub/b.pdf (glob)
*/fixture/a.txt (glob)

$ moonx q2316367743/moonsearch/cmd/moonsearch search --live --root fixture --type file --sort type
*/fixture/sub/b.pdf (glob)
*/fixture/a.txt (glob)
*/fixture/.hidden (glob)

$ moonx q2316367743/moonsearch/cmd/moonsearch search --live --root fixture --type file --sort size -n 2
*/fixture/sub/b.pdf (glob)
*/fixture/a.txt (glob)

$ moonx q2316367743/moonsearch/cmd/moonsearch search --live --root fixture --type file --reverse -n 2
*/fixture/sub/b.pdf (glob)
*/fixture/a.txt (glob)

$ moonx q2316367743/moonsearch/cmd/moonsearch search --live --root fixture --folders-first
*/fixture (glob)
*/fixture/sub (glob)
*/fixture/.hidden (glob)
*/fixture/a.txt (glob)
*/fixture/sub/b.pdf (glob)

$ moonx q2316367743/moonsearch/cmd/moonsearch search --live --root fixture --type file --basename
.hidden
a.txt
b.pdf

$ moonx q2316367743/moonsearch/cmd/moonsearch search --live --root fixture --type file --sort size --relative-to fixture
sub/b.pdf
a.txt
.hidden

$ moonx q2316367743/moonsearch/cmd/moonsearch search --live --root fixture --type file --sort size --relative-to fixture --format "{path}|{size}|{ext}|{type}|{kind}"
sub/b.pdf|1|pdf|doc|file
a.txt|5|txt|doc|file
.hidden|6||other|file

$ moonx q2316367743/moonsearch/cmd/moonsearch search --live --root fixture --type file --sort size --relative-to fixture --json -n 1
\{"path":"sub/b\.pdf","name":"b\.pdf","size":1,"mtime":[0-9]+,"ext":"pdf","type":"doc","kind":"file"\} (regex)
$ moonx q2316367743/moonsearch/cmd/moonsearch search --live --root fixture --type file --sort size --engine bitmap
*/fixture/sub/b.pdf (glob)
*/fixture/a.txt (glob)
*/fixture/.hidden (glob)

$ moonx q2316367743/moonsearch/cmd/moonsearch search --live --root fixture --sort bogus
@STDOUT (empty)
@STDERR
error: --sort must be name, path, size, mtime, ext, or type, got 'bogus'
[2]

$ moonx q2316367743/moonsearch/cmd/moonsearch search --live --root fixture --json --format "{path}"
@STDOUT (empty)
@STDERR
error: --json and --format cannot be combined
[2]

$ moonx q2316367743/moonsearch/cmd/moonsearch search --live --root fixture --format "{bogus}"
@STDOUT (empty)
@STDERR
error: unknown format placeholder '{bogus}'
[2]
```
