///|
/// Per-result output format selected by the CLI.
///
/// `Paths` is the default full path, `Names` is `--basename`, `Json` is one
/// JSON object per result, and `Template` is a parsed `--format` string.
pub(all) enum OutputFormat {
  Paths
  Names
  Json
  Template(FormatTemplate)
}

///|
/// One literal or placeholder in a `--format` template.
priv enum FormatSegment {
  Literal(String)
  Path
  Name
  Dir
  Size
  MTime
  Ext
  Type
  Kind
}

///|
/// A parsed `--format` template.
///
/// Parsing happens once before the search runs, so an unknown placeholder is a
/// usage error instead of a malformed line halfway through the output. Braces
/// always start a placeholder; a literal brace is not supported in this
/// version.
pub struct FormatTemplate {
  priv segments : Array[FormatSegment]
}

///|
/// Parse a format template.
///
/// Supported placeholders are `{path}`, `{name}`, `{dir}`, `{size}`, `{mtime}`,
/// `{ext}`, `{type}`, and `{kind}`. `\n`, `\t`, `\0`, and `\\` are the only
/// escapes; any other backslash sequence is kept verbatim.
pub fn FormatTemplate::parse(
  text : StringView,
) -> Result[FormatTemplate, String] {
  let segments : Array[FormatSegment] = []
  let literal = StringBuilder()
  let mut index = 0
  while index < text.length() {
    match text.get_char(index) {
      Some('\\') =>
        if index + 1 < text.length() {
          match text.get_char(index + 1) {
            Some('n') => literal.write_char('\n')
            Some('t') => literal.write_char('\t')
            Some('0') => literal.write_char('\u{0}')
            Some('\\') => literal.write_char('\\')
            Some(other) => {
              literal.write_char('\\')
              literal.write_char(other)
            }
            None => literal.write_char('\\')
          }
          index = index + 2
        } else {
          literal.write_char('\\')
          index = index + 1
        }
      Some('{') => {
        let mut end = index + 1
        while end < text.length() && !(text.get_char(end) is Some('}')) {
          end = end + 1
        }
        if end >= text.length() {
          return Err("unterminated format placeholder")
        }
        let name = text[index + 1:end]
        let segment = match placeholder_of(name) {
          Some(segment) => segment
          None => return Err("unknown format placeholder '{\{name}}'")
        }
        flush_literal(segments, literal)
        segments.push(segment)
        index = end + 1
      }
      Some(char) => {
        literal.write_char(char)
        index = index + 1
      }
      None => index = index + 1
    }
  }
  flush_literal(segments, literal)
  Ok({ segments, })
}

///|
/// Move the pending literal, if any, into the segment list.
fn flush_literal(
  segments : Array[FormatSegment],
  literal : StringBuilder,
) -> Unit {
  if !literal.is_empty() {
    segments.push(Literal(literal.to_string()))
    literal.reset()
  }
}

///|
/// Map a placeholder name to its segment.
fn placeholder_of(name : StringView) -> FormatSegment? {
  if name == "path" {
    Some(Path)
  } else if name == "name" {
    Some(Name)
  } else if name == "dir" {
    Some(Dir)
  } else if name == "size" {
    Some(Size)
  } else if name == "mtime" {
    Some(MTime)
  } else if name == "ext" {
    Some(Ext)
  } else if name == "type" {
    Some(Type)
  } else if name == "kind" {
    Some(Kind)
  } else {
    None
  }
}

///|
/// How to render and terminate each result.
pub(all) struct FormatOptions {
  format : OutputFormat
  /// Terminate every record with NUL instead of separating records with a
  /// newline. The last record is terminated too, which is what `xargs -0`
  /// expects.
  null_terminated : Bool
  /// Absolute directory to print paths relative to, or `None` for full paths.
  relative_to : String?
}

///|
/// Build format options.
pub fn FormatOptions::new(
  format~ : OutputFormat = Paths,
  null_terminated~ : Bool = false,
  relative_to~ : String? = None,
) -> FormatOptions {
  { format, null_terminated, relative_to, }
}

///|
/// Values shared by every record of one `format_hits` call.
///
/// The relative base bytes, the extension → category table, and the store are
/// prepared once instead of per record.
priv struct FormatContext {
  store : @core.Store
  relative_base : Bytes?
  categories : Map[Bytes, @util.TypeCategory]
}

///|
/// Render every match.
///
/// Newline mode separates records and leaves the final record unterminated;
/// the CLI entry point adds the final newline. NUL mode terminates every
/// record, including the last, so the bytes can be split losslessly.
pub fn format_hits(
  store : @core.Store,
  hits : Array[@core.EntryRef],
  options : FormatOptions,
) -> String {
  let context : FormatContext = {
    store,
    relative_base: match options.relative_to {
      Some(base) => Some(@utf8.encode(base[:]))
      None => None
    },
    categories: type_category_map(),
  }
  let out = StringBuilder()
  let mut index = 0
  while index < hits.length() {
    if index > 0 {
      if options.null_terminated {
        out.write_char('\u{0}')
      } else {
        out.write_char('\n')
      }
    }
    write_record(context, hits[index], options, out)
    index = index + 1
  }
  if options.null_terminated && hits.length() > 0 {
    out.write_char('\u{0}')
  }
  out.to_string()
}

///|
/// Render one match.
fn write_record(
  context : FormatContext,
  entry : @core.EntryRef,
  options : FormatOptions,
  out : StringBuilder,
) -> Unit {
  match options.format {
    Paths => out.write_string(output_path(context, entry))
    Names =>
      out.write_string(@utf8.decode_lossy(context.store.entry_name(entry)))
    Json => write_json_record(context, entry, out)
    Template(template) => write_template(context, entry, template, out)
  }
}

///|
/// Render a template for one match.
fn write_template(
  context : FormatContext,
  entry : @core.EntryRef,
  template : FormatTemplate,
  out : StringBuilder,
) -> Unit {
  for segment in template.segments {
    match segment {
      Literal(text) => out.write_string(text)
      Path => out.write_string(output_path(context, entry))
      Name =>
        out.write_string(@utf8.decode_lossy(context.store.entry_name(entry)))
      Dir => out.write_string(directory_of(output_path(context, entry)))
      Size => out.write_string(size_string(context.store, entry))
      MTime => out.write_string(mtime_string(context.store, entry))
      Ext => out.write_string(extension_string(context.store, entry))
      Type => out.write_string(type_string(context, entry))
      Kind => out.write_string(kind_string(entry))
    }
  }
}

///|
/// Write one JSON Lines record.
///
/// The field order is stable so golden tests can assert whole lines. `type` is
/// the built-in category name, `other` for an unlisted file extension, and
/// `folder` for folders.
fn write_json_record(
  context : FormatContext,
  entry : @core.EntryRef,
  out : StringBuilder,
) -> Unit {
  out.write_char('{')
  out.write_string("\"path\":")
  write_json_string(out, output_path(context, entry))
  out.write_string(",\"name\":")
  write_json_string(out, @utf8.decode_lossy(context.store.entry_name(entry)))
  out.write_string(",\"size\":")
  out.write_string(size_string(context.store, entry))
  out.write_string(",\"mtime\":")
  out.write_string(mtime_string(context.store, entry))
  out.write_string(",\"ext\":")
  write_json_string(out, extension_string(context.store, entry))
  out.write_string(",\"type\":")
  write_json_string(out, type_string(context, entry))
  out.write_string(",\"kind\":")
  write_json_string(out, kind_string(entry))
  out.write_char('}')
}

///|
/// Write a JSON string literal.
fn write_json_string(out : StringBuilder, text : StringView) -> Unit {
  out.write_char('"')
  let mut index = 0
  while index < text.length() {
    match text.get_char(index) {
      Some('"') => out.write_string("\\\"")
      Some('\\') => out.write_string("\\\\")
      Some('\u{8}') => out.write_string("\\b")
      Some('\u{c}') => out.write_string("\\f")
      Some('\n') => out.write_string("\\n")
      Some('\r') => out.write_string("\\r")
      Some('\t') => out.write_string("\\t")
      Some(char) =>
        if char.to_int() < 0x20 {
          out.write_string("\\u00")
          out.write_char(hex_digit((char.to_int() >> 4) & 0xF))
          out.write_char(hex_digit(char.to_int() & 0xF))
        } else {
          out.write_char(char)
        }
      None => ()
    }
    index = index + 1
  }
  out.write_char('"')
}

///|
/// One lowercase hexadecimal digit.
fn hex_digit(value : Int32) -> Char {
  match "0123456789abcdef".get_char(value) {
    Some(char) => char
    None => '0'
  }
}

///|
/// Path to print for one entry, relative to the prepared base if it is under
/// it.
fn output_path(context : FormatContext, entry : @core.EntryRef) -> String {
  let path = context.store.entry_path(entry)
  match context.relative_base {
    Some(base) => @utf8.decode_lossy(relativize(path, base[:])[:])
    None => @utf8.decode_lossy(path[:])
  }
}

///|
/// Strip `base` and one separator from `path`.
///
/// Paths outside the base, and the degenerate empty base, are returned
/// unchanged. A path equal to the base becomes `.`, which is the conventional
/// relative name for the directory itself.
fn relativize(path : Bytes, base : BytesView) -> Bytes {
  if base.length() == 0 {
    return path
  }
  let mut base_len = base.length()
  while base_len > 1 && base[base_len - 1] == b'/' {
    base_len = base_len - 1
  }
  if base_len == 1 && base[0] == b'/' {
    if path.length() == 1 && path[0] == b'/' {
      return b"."
    }
    if path.length() > 0 && path[0] == b'/' {
      return path[1:].to_owned()
    }
    return path
  }
  if path.length() == base_len && @util.starts_with(path[:], base[:base_len]) {
    return b"."
  }
  if path.length() > base_len &&
    @util.starts_with(path[:], base[:base_len]) &&
    path[base_len] == b'/' {
    return path[base_len + 1:].to_owned()
  }
  path
}

///|
/// Parent directory of an output path.
///
/// An absolute path with one component maps to `/`; a relative path without a
/// separator maps to `.`.
fn directory_of(path : String) -> String {
  if path.is_empty() {
    return ""
  }
  let mut index = path.length() - 1
  while index >= 0 {
    if path.get_char(index) is Some('/') {
      if index == 0 {
        return "/"
      }
      return path[:index].to_owned()
    }
    index = index - 1
  }
  "."
}

///|
/// Size as decimal text; folders report their subtree total.
fn size_string(store : @core.Store, entry : @core.EntryRef) -> String {
  match store.entry_size(entry) {
    Some(value) => value.to_string()
    None => "0"
  }
}

///|
/// Modification time as Unix seconds.
fn mtime_string(store : @core.Store, entry : @core.EntryRef) -> String {
  match store.entry_mtime(entry) {
    Some(value) => value.to_string()
    None => "0"
  }
}

///|
/// ASCII-lowercase extension; folders always report an empty extension.
fn extension_string(store : @core.Store, entry : @core.EntryRef) -> String {
  @utf8.decode_lossy(@util.ascii_fold(store.entry_extension(entry))[:])
}

///|
/// Category name for files, `folder` for folders, `other` for unlisted
/// extensions.
fn type_string(context : FormatContext, entry : @core.EntryRef) -> String {
  if entry.is_folder() {
    "folder"
  } else {
    let ext = @util.ascii_fold(context.store.entry_extension(entry))
    match context.categories.get_from_bytes(ext[:]) {
      Some(category) => category.name()
      None => "other"
    }
  }
}

///|
/// `file` or `folder`.
fn kind_string(entry : @core.EntryRef) -> String {
  if entry.is_file() {
    "file"
  } else {
    "folder"
  }
}
