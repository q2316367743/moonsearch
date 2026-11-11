///|
/// Process exit codes shared by every subcommand.
///
/// The values follow the grep convention documented in `MIGRATION_PLAN.md`
/// section 7.3: `0` success, `1` no match, `2` usage or runtime error.
pub const EXIT_OK : Int32 = 0

///|
/// The query was valid but nothing matched.
pub const EXIT_NO_MATCH : Int32 = 1

///|
/// Argument, query, IO, or database error.
pub const EXIT_ERROR : Int32 = 2

///|
/// Interrupted by SIGINT. Reserved for the runtime signal handler.
pub const EXIT_INTERRUPTED : Int32 = 130
