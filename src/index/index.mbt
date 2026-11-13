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
}

///|
/// Build every candidate source for a finished store.
///
/// `eager` selects the range fields built immediately; the rest materialize on
/// first use. The default matches `Ranges::build` (every field), while the CLI
/// passes its own `--fast-fields` selection. `trigram` builds the postings
/// unless the caller wants a `--no-trigram` comparison index, in which case
/// ordinary name terms fall back to a full scan.
pub fn Index::build(
  store : @core.Store,
  eager~ : RangeFieldSet = RangeFieldSet::all(),
  trigram~ : Bool = true,
) -> Index {
  let ranges = Ranges::build(store, eager~)
  let dict = Dict::build(store)
  let postings = if trigram { Some(TrigramIndex::build(store)) } else { None }
  { store, dict, ranges, trigram: postings, }
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
/// Number of entries the index covers.
pub fn Index::entry_count(self : Index) -> Int32 {
  self.store.entry_count()
}
