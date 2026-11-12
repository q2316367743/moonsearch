///|
/// Built-in file categories behind the `app:`, `archive:`, `audio:`, `doc:`,
/// `pic:`, and `video:` macros.
///
/// A category is a fixed set of extensions. The query layer turns a category
/// macro into a `TypeCategory` term, the scan engine matches it against this
/// table, and the field dictionary materializes it as one bitmap at build time.
/// Both paths read the same lists, so the two engines cannot drift apart.
pub(all) enum TypeCategory {
  App
  Archive
  Audio
  Doc
  Pic
  Video
}

///|
/// Every category, in a stable order.
pub fn TypeCategory::all() -> Array[TypeCategory] {
  [App, Archive, Audio, Doc, Pic, Video]
}

///|
/// Dense index of the category in `TypeCategory::all()` order.
///
/// The field dictionary stores one set per category in this order, so a lookup
/// is an array index rather than an enum comparison.
pub fn TypeCategory::index(self : TypeCategory) -> Int32 {
  match self {
    App => 0
    Archive => 1
    Audio => 2
    Doc => 3
    Pic => 4
    Video => 5
  }
}

///|
/// Macro name of the category, ASCII lowercase.
pub fn TypeCategory::name(self : TypeCategory) -> String {
  match self {
    App => "app"
    Archive => "archive"
    Audio => "audio"
    Doc => "doc"
    Pic => "pic"
    Video => "video"
  }
}

///|
/// Parse a macro name into a built-in category.
///
/// Names are ASCII case-insensitive, like every other field and macro name.
/// `None` means the name is not a built-in macro; a user macro with that name
/// still takes precedence because the parser checks the user table first.
pub fn TypeCategory::from_name(name : StringView) -> TypeCategory? {
  if ascii_name_eq(name, "app") {
    Some(App)
  } else if ascii_name_eq(name, "archive") {
    Some(Archive)
  } else if ascii_name_eq(name, "audio") {
    Some(Audio)
  } else if ascii_name_eq(name, "doc") {
    Some(Doc)
  } else if ascii_name_eq(name, "pic") {
    Some(Pic)
  } else if ascii_name_eq(name, "video") {
    Some(Video)
  } else {
    None
  }
}

///|
/// Extensions that belong to the category, ASCII lowercase and without dots.
///
/// The lists are this project's own; they name common formats for each kind of
/// file and are not copied from another search tool. An extension may appear in
/// two categories (a transport stream is both a video and, rarely, a document);
/// the categories are independent unions, so that is not a conflict.
pub fn TypeCategory::extensions(self : TypeCategory) -> Array[String] {
  match self {
    App =>
      [
        "app", "appimage", "deb", "desktop", "dmg", "exe", "flatpak", "msi", "pkg",
        "rpm", "snap",
      ]
    Archive =>
      [
        "7z", "bz2", "cab", "gz", "gzip", "iso", "jar", "lz4", "lzma", "rar", "tar",
        "tbz2", "tgz", "txz", "xz", "zip", "zst",
      ]
    Audio =>
      [
        "aac", "ac3", "aiff", "alac", "ape", "au", "flac", "m4a", "mka", "mp3", "oga",
        "ogg", "opus", "wav", "wma", "wv",
      ]
    Doc =>
      [
        "c", "cc", "chm", "cpp", "csv", "cxx", "doc", "docx", "epub", "go", "h",
        "hpp", "htm", "html", "ini", "java", "js", "json", "log", "lua", "md", "mobi",
        "mbt", "odt", "pdf", "ppt", "pptx", "py", "rb", "rs", "rtf", "sh", "tex",
        "toml", "ts", "tsv", "txt", "xls", "xlsx", "xml", "yaml", "yml",
      ]
    Pic =>
      [
        "avif", "bmp", "gif", "heic", "ico", "jpeg", "jpg", "png", "psd", "svg",
        "tif", "tiff", "webp", "xcf",
      ]
    Video =>
      [
        "3gp", "avi", "flv", "m4v", "mkv", "mov", "mp4", "mpeg", "mpg", "ogv", "rmvb",
        "vob", "webm", "wmv",
      ]
  }
}

///|
/// Whether `text` equals an ASCII lowercase literal after ASCII case folding.
///
/// Macro and field names are ASCII in practice; a non-ASCII code unit simply
/// never matches the literal.
fn ascii_name_eq(text : StringView, expected : StringView) -> Bool {
  if text.length() != expected.length() {
    return false
  }
  let mut index = 0
  while index < text.length() {
    let actual = match text.get_char(index) {
      Some(char) => char
      None => return false
    }
    let target = match expected.get_char(index) {
      Some(char) => char
      None => return false
    }
    if actual.to_ascii_lowercase() != target {
      return false
    }
    index = index + 1
  }
  true
}
