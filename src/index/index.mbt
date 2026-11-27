///|
/// An immutable search index: one store plus every candidate source built from
/// it.
///
/// `Dict`, `Ranges`, and the trigram postings are derived from the same `Store`,
/// share its global id space, and are read-only once built. Bundling them keeps
/// the query compiler from threading four values through every call and gives
/// the persistence step a single object to serialize and restore.
///
/// The bundle is a value like the parts it holds: copying it shares the arrays
/// (nothing is duplicated), so treat every accessor result as read-only.
pub struct Index {
  priv store : @core.Store
  priv dict : Dict
  priv ranges : Ranges
  priv trigram : TrigramIndex?
  /// Scan-time rules retained so `update` can reproduce the original filter
  /// when neither CLI nor configuration supplies a replacement.
  priv excludes : Array[ExcludeRule]
}

///|
/// Build every candidate source for a finished store.
///
/// `eager` selects optional range fields built immediately in addition to the
/// five core fields, which are always built and persisted. On database load the
/// same selection controls eager decoding; unselected core fields decode from
/// their persisted slices on first use. The default matches `Ranges::build`
/// (every field), while the CLI passes its `--fast-fields` selection.
/// `trigram` builds the postings unless the caller wants a `--no-trigram`
/// comparison index, in which case ordinary name terms fall back to a full scan.
pub fn Index::build(
  store : @core.Store,
  eager~ : RangeFieldSet = RangeFieldSet::all(),
  trigram~ : Bool = true,
  excludes~ : Array[ExcludeRule] = [],
) -> Index {
  let selected = RangeFieldSet::core().union(eager)
  let ranges = Ranges::build(store, eager=selected)
  let dict = Dict::build(store)
  let postings = if trigram { Some(TrigramIndex::build(store)) } else { None }
  { store, dict, ranges, trigram: postings, excludes, }
}

///|
/// Restore an index whose parts were decoded from a database.
///
/// `Index::build` remains the scan-side constructor. The loader has already
/// validated every part against the store; this function only bundles them so
/// queries can run without rebuilding the dictionary, the ranges, or the
/// trigram postings.
pub fn Index::restore(
  store~ : @core.Store,
  dict~ : Dict,
  ranges~ : Ranges,
  trigram~ : TrigramIndex? = None,
  excludes~ : Array[ExcludeRule] = [],
) -> Index {
  { store, dict, ranges, trigram, excludes, }
}

///|
/// The store the index was built over.
pub fn Index::store(self : Index) -> @core.Store {
  self.store
}

///|
/// The low-cardinality field dictionary.
pub fn Index::dict(self : Index) -> Dict {
  self.dict
}

///|
/// The range indexes. Lazy fields materialize on first use.
pub fn Index::ranges(self : Index) -> Ranges {
  self.ranges
}

///|
/// The trigram inverted index, or `None` when it was disabled.
pub fn Index::trigram(self : Index) -> TrigramIndex? {
  self.trigram
}

///|
/// Exclude rules used by the scan that produced this index.
///
/// The rules are configuration snapshots, not query predicates. `update` uses
/// them only when no CLI or configuration-file rules replace them.
pub fn Index::excludes(self : Index) -> ArrayView[ExcludeRule] {
  self.excludes
}

///|
/// Number of entries the index covers.
pub fn Index::entry_count(self : Index) -> Int32 {
  self.store.entry_count()
}
