///|
/// Public facade for the `moonsearch` library.
///
/// Later steps re-export the store, index, query, and execution APIs here.
pub using @core {
  VERSION,
  VERSION_TEXT,
  EXIT_OK,
  EXIT_NO_MATCH,
  EXIT_ERROR,
  EXIT_INTERRUPTED,
}
