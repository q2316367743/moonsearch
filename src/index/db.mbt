///|
/// Errors raised while reading, writing, or inspecting a database.
///
/// Every decoder failure is reported here instead of panicking: a truncated or
/// corrupted file must leave the process alive and the previous database intact.
pub suberror DbError {
  /// The database file does not exist.
  NotFound(String)
  /// The operating system rejected a read or write.
  Io(String)
  /// Another process holds the writer lock.
  Locked(String)
  /// The file ends before a declared structure is complete.
  Truncated
  /// The file is structurally invalid.
  Corrupt(String)
  /// A struct this version cannot interpret.
  UnsupportedVersion(major~ : Int32, minor~ : Int32)
  /// The encoded index would exceed the byte-buffer limit.
  TooLarge(String)
}

///|
/// Human-readable text of a database error.
pub fn DbError::message(self : DbError) -> String {
  match self {
    NotFound(path) => "database does not exist: \{path}"
    Io(message) => message
    Locked(path) =>
      "another process is writing the index at \{path}; try again later"
    Truncated => "database is truncated"
    Corrupt(message) => "database is corrupt: \{message}"
    UnsupportedVersion(major~, minor~) =>
      "database format \{major}.\{minor} is not supported"
    TooLarge(message) => "database is too large: \{message}"
  }
}

///|
/// Size and kind of one persisted section, shown by `info`.
pub(all) struct DbSectionInfo {
  name : String
  length : Int64
}

///|
/// Header-level information about a database, read without loading the index.
pub(all) struct DbInfo {
  format_major : Int32
  format_minor : Int32
  built_at : Int64
  folder_count : Int32
  file_count : Int32
  root_count : Int32
  name_count : Int32
  trigram_count : Int32
  file_size : Int64
  sections : Array[DbSectionInfo]
}

///|
/// Number of entries described by the header.
pub fn DbInfo::entry_count(self : DbInfo) -> Int32 {
  self.folder_count + self.file_count
}

///|
/// Read a database file and decode the whole index.
///
/// `verify=true` checks the payload checksum in addition to the metadata
/// checksum, which costs one pass over the file. `budget` can tighten the default
/// Ids/posting decode limits for constrained callers.
pub async fn Index::read_database(
  path : StringView,
  verify~ : Bool = false,
  budget~ : @ids.IdsDecodeBudget? = None,
) -> Index raise DbError {
  let bytes = read_database_bytes(path)
  Index::from_bytes(bytes[:], verify~, budget~)
}

///|
/// Read only the header and section table.
///
/// This is what `info` uses: it answers questions about a multi-hundred-megabyte
/// index without allocating the store or rebuilding any structure.
pub async fn read_database_info(
  path : StringView,
  verify~ : Bool = false,
) -> DbInfo raise DbError {
  let bytes = read_database_bytes(path)
  DbInfo::from_bytes(bytes[:], verify~)
}

///|
/// Write the index to `path` with the documented atomic-replace sequence.
///
/// The encoded bytes go to `<path>.tmp.<timestamp>` in the same directory, are
/// synced, and are then renamed over `path`. A writer lock serialises concurrent
/// `index`/`update` processes; readers never take the lock because the rename is
/// atomic. On failure the temporary file is removed and the old database stays
/// in place.
pub async fn Index::write_database(
  self : Index,
  path : StringView,
) -> Unit raise DbError {
  let bytes = self.to_bytes()
  write_database_bytes(path, bytes)
}

///|
/// Read a database file into memory.
async fn read_database_bytes(path : StringView) -> Bytes raise DbError {
  let exists = @fs.exists(path) catch { _ => false }
  if !exists {
    raise DbError::NotFound("\{path}")
  }
  let file = @fs.open(path, mode=ReadOnly) catch {
    err => raise DbError::Io("cannot open database \{path}: \{err}")
  }
  errdefer file.close()
  let size = file.size() catch {
    err => raise DbError::Io("cannot stat database \{path}: \{err}")
  }
  ensure_database_size(size, path)
  // Read only the size that was checked, then peek one extra byte. A file that
  // grows after the stat is rejected instead of being allocated in full.
  let bytes = file.read_exactly(size.to_int()) catch {
    _ => raise DbError::Truncated
  }
  let has_extra = try {
    ignore(file.peek_exactly(1))
    true
  } catch {
    @io.ReaderError::UnexpectedEof => false
    _ => raise DbError::Io("cannot read database \{path}")
  }
  if has_extra {
    raise DbError::TooLarge(
      "database \{path} grew beyond the 2 GiB byte-buffer limit",
    )
  }
  file.close()
  bytes
}

///|
/// Enforce the byte-buffer limit before reading a database into memory.
fn ensure_database_size(size : Int64, path : StringView) -> Unit raise DbError {
  if size < 0L {
    raise DbError::Io("cannot determine the size of database \{path}")
  }
  if size > DB_MAX_FILE_BYTES {
    raise DbError::TooLarge(
      "database \{path} exceeds the 2 GiB byte-buffer limit",
    )
  }
}

///|
/// Create the database's parent directory when it does not exist yet.
async fn ensure_database_dir(path : StringView) -> Unit raise DbError {
  let parent = database_parent(path)
  match parent {
    Some(dir) =>
      @fs.mkdir(dir, recursive=true, allow_existing=true) catch {
        err => raise DbError::Io("cannot create \{dir}: \{err}")
      }
    None => ()
  }
}

///|
/// Directory portion of a database path, or `None` for a bare file name.
fn database_parent(path : StringView) -> String? {
  match path.rev_find("/") {
    Some(index) =>
      if index == 0 {
        Some("/")
      } else {
        Some(path[:index].to_owned())
      }
    None => None
  }
}

///|
/// Write bytes to a same-directory temporary file, sync it, and rename it into
/// place while holding the writer lock.
async fn write_database_bytes(
  path : StringView,
  bytes : Bytes,
) -> Unit raise DbError {
  ensure_database_dir(path)
  let lock_path = "\{path}.lock"
  let lock = @fs.open(lock_path, mode=WriteOnly, create_mode=OpenOrCreate) catch {
    err => raise DbError::Io("cannot open the index lock \{lock_path}: \{err}")
  }
  let acquired = lock.try_lock(Exclusive) catch {
    err => {
      lock.close()
      raise DbError::Io("cannot lock \{lock_path}: \{err}")
    }
  }
  if !acquired {
    lock.close()
    raise DbError::Locked("\{path}")
  }
  let temporary = "\{path}.tmp.\{@env.now()}"
  let written = try {
    @fs.write_binary(
      temporary,
      bytes[:],
      create_mode=CreateOrTruncate,
      sync=Full,
    )
    @fs.rename(temporary, path, replace=true)
  } catch {
    err => {
      @fs.remove(temporary, allow_missing=true) catch {
        _ => ()
      }
      lock.close()
      raise DbError::Io("cannot write database \{path}: \{err}")
    }
  }
  ignore(written)
  lock.close()
}
