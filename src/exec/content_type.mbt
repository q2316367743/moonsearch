///|
/// Extension-to-MIME table used by `contenttype:`.
///
/// `MIGRATION_PLAN.md` section 5.11 keeps v1 free of libmagic: the content type
/// is inferred from the extension alone. The table covers the common document,
/// image, audio, video, archive, and source-code extensions; everything else is
/// `application/octet-stream`, which is also what an unknown file would get from
/// a magic-based lookup.
fn mime_of_extension(extension : BytesView) -> String {
  match ascii_string_of(extension) {
    "txt" | "text" | "md" | "markdown" | "log" | "rst" | "adoc" => "text/plain"
    "html" | "htm" => "text/html"
    "css" => "text/css"
    "csv" | "tsv" => "text/csv"
    "json" | "jsonl" | "ndjson" => "application/json"
    "xml" => "application/xml"
    "yaml" | "yml" => "application/x-yaml"
    "toml" => "application/toml"
    "js" | "mjs" | "cjs" => "application/javascript"
    "ts" | "tsx" | "mbt" => "text/plain"
    "c" | "h" => "text/x-c"
    "cc" | "cpp" | "cxx" | "hpp" => "text/x-c++"
    "rs" => "text/x-rust"
    "go" => "text/x-go"
    "py" => "text/x-python"
    "sh" | "bash" | "zsh" => "text/x-shellscript"
    "pdf" => "application/pdf"
    "zip" | "jar" => "application/zip"
    "gz" | "tgz" => "application/gzip"
    "tar" => "application/x-tar"
    "bz2" => "application/x-bzip2"
    "xz" => "application/x-xz"
    "zst" => "application/zstd"
    "7z" => "application/x-7z-compressed"
    "rar" => "application/vnd.rar"
    "jpg" | "jpeg" => "image/jpeg"
    "png" => "image/png"
    "gif" => "image/gif"
    "webp" => "image/webp"
    "bmp" => "image/bmp"
    "svg" => "image/svg+xml"
    "tif" | "tiff" => "image/tiff"
    "ico" => "image/x-icon"
    "heic" => "image/heic"
    "mp3" => "audio/mpeg"
    "flac" => "audio/flac"
    "wav" => "audio/wav"
    "ogg" | "oga" => "audio/ogg"
    "m4a" | "aac" => "audio/mp4"
    "opus" => "audio/opus"
    "mp4" | "m4v" => "video/mp4"
    "mkv" => "video/x-matroska"
    "avi" => "video/x-msvideo"
    "mov" => "video/quicktime"
    "webm" => "video/webm"
    "wmv" => "video/x-ms-wmv"
    "flv" => "video/x-flv"
    _ => "application/octet-stream"
  }
}

///|
/// Match a `contenttype:` value against an entry.
///
/// Folders have no extension and never match. A value containing `/` must equal
/// the whole MIME type (`application/pdf`); a value without one selects either
/// the main type (`text` matches every `text/*`) or the subtype (`pdf` matches
/// `application/pdf`), which is what users type in practice.
fn match_content_type(
  store : @core.Store,
  entry : @core.EntryRef,
  value : String,
) -> Bool {
  if entry.kind is @core.Folder {
    return false
  }
  let mime = mime_of_extension(@util.extension_of(store.entry_name(entry)))
  if value.contains_char('/') {
    mime == value
  } else {
    match mime.split_once("/") {
      Some((main_type, sub_type)) =>
        main_type.equal_to_string(value) || sub_type.equal_to_string(value)
      None => mime == value
    }
  }
}

///|
/// Lowercase ASCII bytes into a `String`.
///
/// Extensions are ASCII by convention; a non-ASCII byte is preserved as its own
/// code unit, which simply never matches a table entry.
fn ascii_string_of(bytes : BytesView) -> String {
  let chars : Array[Char] = []
  for byte in bytes.iter() {
    chars.push(@util.ascii_lower(byte).to_char())
  }
  String::from_array(chars)
}
