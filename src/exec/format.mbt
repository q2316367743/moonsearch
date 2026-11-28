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
  /// Terminate every record with NUL instead of newline. The last record is
  /// terminated too, which is what `xargs -0` expects.
  null_terminated : Bool
  /// Absolute directory to print paths relative to, or `None` for full paths.
  relative_to : Bytes?
}

///|
/// Build format options.
pub fn FormatOptions::new(
  format~ : OutputFormat = Paths,
  null_terminated~ : Bool = false,
  relative_to~ : Bytes? = None,
) -> FormatOptions {
  { format, null_terminated, relative_to, }
}

///|
/// Complete stdout bytes plus the number of JSON records that needed lossy
/// UTF-8 decoding. Raw path/name/template formats never set the warning count.
pub struct FormatOutput {
  bytes : Bytes
  invalid_utf8_records : Int32
  null_terminated : Bool
}

///|
/// Complete stdout bytes: add the final newline only in newline mode.
pub fn FormatOutput::stdout_bytes(self : FormatOutput) -> Bytes {
  if self.null_terminated || self.bytes.is_empty() {
    return self.bytes
  }
  let out = @buffer.Buffer()
  out.write_bytesview(self.bytes)
  out.write_byte(b'\n')
  out.to_bytes()
}

///|
/// Stable stderr warning for JSON output containing invalid UTF-8.
pub fn FormatOutput::warning(self : FormatOutput) -> String? {
  if self.invalid_utf8_records > 0 {
    Some(
      "warning: replaced invalid UTF-8 in \{self.invalid_utf8_records} JSON record(s) with U+FFFD",
    )
  } else {
    None
  }
}

///|
/// Values shared by every record of one `format_hits` call.
priv struct FormatContext {
  store : @core.Store
  relative_base : Bytes?
  categories : Map[Bytes, @util.TypeCategory]
}

///|
/// Render every match into record bytes.
///
/// Newline mode separates records and leaves the final record unterminated;
/// `stdout_bytes` adds the final newline. NUL mode terminates every record,
/// including the last, with exactly one `\0`.
pub fn format_hits(
  store : @core.Store,
  hits : Array[@core.EntryRef],
  options : FormatOptions,
) -> FormatOutput {
  let context : FormatContext = {
    store,
    relative_base: options.relative_to,
    categories: type_category_map(),
  }
  let out = @buffer.Buffer()
  let mut invalid_records = 0
  let mut index = 0
  while index < hits.length() {
    if index > 0 {
      out.write_byte(if options.null_terminated { b'\x00' } else { b'\n' })
    }
    if write_record(context, hits[index], options, out) {
      invalid_records = invalid_records + 1
    }
    index = index + 1
  }
  if options.null_terminated && hits.length() > 0 {
    out.write_byte(b'\x00')
  }
  {
    bytes: out.to_bytes(),
    invalid_utf8_records: invalid_records,
    null_terminated: options.null_terminated,
  }
}

///|
/// Whether a template reads folder-subtree size.
pub fn FormatTemplate::uses_size(self : FormatTemplate) -> Bool {
  for segment in self.segments {
    if segment is Size {
      return true
    }
  }
  false
}

///|
/// Render and terminate one live entry. Unlike `format_hits`, every record is
/// complete so it can be written to stdout before the scan continues.
pub fn format_entry(entry : EntryView, options : FormatOptions) -> FormatOutput {
  let out = @buffer.Buffer()
  let invalid = match options.format {
    Paths => {
      out.write_bytesview(view_output_path(entry.path, options.relative_to))
      false
    }
    Names => {
      out.write_bytesview(entry.name[:])
      false
    }
    Json => write_view_json(entry, options, out)
    Template(template) => {
      for segment in template.segments {
        match segment {
          Literal(text) => out.write_string_utf8(text)
          Path =>
            out.write_bytesview(
              view_output_path(entry.path, options.relative_to),
            )
          Name => out.write_bytesview(entry.name[:])
          Dir =>
            out.write_bytesview(
              directory_of(view_output_path(entry.path, options.relative_to)),
            )
          Size => out.write_string_utf8(entry.size.to_string())
          MTime => out.write_string_utf8(entry.mtime.to_string())
          Ext => out.write_bytesview(view_extension(entry))
          Type => out.write_string_utf8(view_type(entry))
          Kind => out.write_string_utf8(view_kind(entry))
        }
      }
      false
    }
  }
  out.write_byte(if options.null_terminated { b'\x00' } else { b'\n' })
  {
    bytes: out.to_bytes(),
    invalid_utf8_records: if invalid {
      1
    } else {
      0
    },
    null_terminated: options.null_terminated,
  }
}

///|
/// Path for one live entry.
fn view_output_path(path : Bytes, relative_base : Bytes?) -> Bytes {
  match relative_base {
    Some(base) => relativize(path, base[:])
    None => path
  }
}

///|
/// Extension bytes for one live entry.
fn view_extension(entry : EntryView) -> Bytes {
  if entry.kind is @core.Folder {
    b""
  } else {
    @util.ascii_fold(@util.extension_of(entry.name[:]))
  }
}

///|
/// Category name for one live entry.
fn view_type(entry : EntryView) -> String {
  if entry.kind is @core.Folder {
    "folder"
  } else {
    let ext = view_extension(entry)
    match type_category_map().get_from_bytes(ext[:]) {
      Some(category) => category.name()
      None => "other"
    }
  }
}

///|
/// Kind text for one live entry.
fn view_kind(entry : EntryView) -> String {
  if entry.kind is @core.File {
    "file"
  } else {
    "folder"
  }
}

///|
/// Write one live JSON record.
fn write_view_json(
  entry : EntryView,
  options : FormatOptions,
  out : @buffer.Buffer,
) -> Bool {
  out.write_string_utf8("{\"path\":")
  let path_valid = write_json_bytes(
    out,
    view_output_path(entry.path, options.relative_to)[:],
  )
  out.write_string_utf8(",\"name\":")
  let name_valid = write_json_bytes(out, entry.name[:])
  out.write_string_utf8(",\"size\":")
  out.write_string_utf8(entry.size.to_string())
  out.write_string_utf8(",\"mtime\":")
  out.write_string_utf8(entry.mtime.to_string())
  out.write_string_utf8(",\"ext\":")
  let ext_valid = write_json_bytes(out, view_extension(entry)[:])
  out.write_string_utf8(",\"type\":")
  write_json_text(out, view_type(entry))
  out.write_string_utf8(",\"kind\":")
  write_json_text(out, view_kind(entry))
  out.write_byte(b'}')
  !(path_valid && name_valid && ext_valid)
}

///|
/// Render one match, returning whether JSON required lossy decoding.
fn write_record(
  context : FormatContext,
  entry : @core.EntryRef,
  options : FormatOptions,
  out : @buffer.Buffer,
) -> Bool {
  match options.format {
    Paths => {
      out.write_bytesview(output_path(context, entry))
      false
    }
    Names => {
      out.write_bytesview(context.store.entry_name(entry))
      false
    }
    Json => write_json_record(context, entry, out)
    Template(template) => {
      write_template(context, entry, template, out)
      false
    }
  }
}

///|
/// Render a template for one match.
fn write_template(
  context : FormatContext,
  entry : @core.EntryRef,
  template : FormatTemplate,
  out : @buffer.Buffer,
) -> Unit {
  for segment in template.segments {
    match segment {
      Literal(text) => out.write_string_utf8(text)
      Path => out.write_bytesview(output_path(context, entry))
      Name => out.write_bytesview(context.store.entry_name(entry))
      Dir => out.write_bytesview(directory_of(output_path(context, entry)))
      Size => out.write_string_utf8(size_string(context.store, entry))
      MTime => out.write_string_utf8(mtime_string(context.store, entry))
      Ext => out.write_bytesview(extension_string(context.store, entry))
      Type => out.write_string_utf8(type_string(context, entry))
      Kind => out.write_string_utf8(kind_string(entry))
    }
  }
}

///|
/// Write one JSON Lines record and report whether any byte field was invalid.
fn write_json_record(
  context : FormatContext,
  entry : @core.EntryRef,
  out : @buffer.Buffer,
) -> Bool {
  out.write_byte(b'{')
  out.write_string_utf8("\"path\":")
  let path_valid = write_json_bytes(out, output_path(context, entry))
  out.write_string_utf8(",\"name\":")
  let name_valid = write_json_bytes(out, context.store.entry_name(entry))
  out.write_string_utf8(",\"size\":")
  out.write_string_utf8(size_string(context.store, entry))
  out.write_string_utf8(",\"mtime\":")
  out.write_string_utf8(mtime_string(context.store, entry))
  out.write_string_utf8(",\"ext\":")
  let ext_valid = write_json_bytes(out, extension_string(context.store, entry))
  out.write_string_utf8(",\"type\":")
  write_json_text(out, type_string(context, entry))
  out.write_string_utf8(",\"kind\":")
  write_json_text(out, kind_string(entry))
  out.write_byte(b'}')
  !(path_valid && name_valid && ext_valid)
}

///|
/// Write raw bytes as a legal JSON string, replacing invalid UTF-8 with U+FFFD.
fn write_json_bytes(out : @buffer.Buffer, bytes : BytesView) -> Bool {
  let (text, valid) = json_text(bytes)
  write_json_text(out, text)
  valid
}

///|
fn json_text(bytes : BytesView) -> (String, Bool) {
  let text = @utf8.decode(bytes) catch {
    _ => return (@utf8.decode_lossy(bytes), false)
  }
  (text, true)
}

///|
/// Write a JSON string literal from already-valid text.
fn write_json_text(out : @buffer.Buffer, text : StringView) -> Unit {
  out.write_byte(b'"')
  let mut index = 0
  while index < text.length() {
    match text.get_char(index) {
      Some('"') => out.write_string_utf8("\\\"")
      Some('\\') => out.write_string_utf8("\\\\")
      Some('\u{8}') => out.write_string_utf8("\\b")
      Some('\u{c}') => out.write_string_utf8("\\f")
      Some('\n') => out.write_string_utf8("\\n")
      Some('\r') => out.write_string_utf8("\\r")
      Some('\t') => out.write_string_utf8("\\t")
      Some(char) =>
        if char.to_int() < 0x20 {
          out.write_string_utf8("\\u00")
          out.write_byte(hex_digit((char.to_int() >> 4) & 0xF))
          out.write_byte(hex_digit(char.to_int() & 0xF))
        } else {
          out.write_string_utf8(char.to_string())
        }
      None => ()
    }
    index = index + 1
  }
  out.write_byte(b'"')
}

///|
/// One lowercase hexadecimal digit as a byte.
fn hex_digit(value : Int32) -> Byte {
  if value >= 0 && value <= 9 {
    (value + 0x30).to_byte()
  } else if value >= 10 && value <= 15 {
    (value + 0x57).to_byte()
  } else {
    b'0'
  }
}

///|
/// Path bytes to print for one entry, relative to the prepared base if needed.
fn output_path(context : FormatContext, entry : @core.EntryRef) -> Bytes {
  let path = context.store.entry_path(entry)
  match context.relative_base {
    Some(base) => relativize(path, base[:])
    None => path
  }
}

///|
/// Strip `base` and one separator from `path`.
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
/// Parent directory of an output path, preserving raw bytes.
fn directory_of(path : Bytes) -> Bytes {
  if path.is_empty() {
    return b""
  }
  let mut index = path.length() - 1
  while index >= 0 {
    if path[index] == b'/' {
      if index == 0 {
        return b"/"
      }
      return path[:index].to_owned()
    }
    index = index - 1
  }
  b"."
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
/// ASCII-lowercase extension bytes; folders always report an empty extension.
fn extension_string(store : @core.Store, entry : @core.EntryRef) -> Bytes {
  @util.ascii_fold(store.entry_extension(entry))
}

///|
/// Category name for files, `folder` for folders, `other` for unlisted extensions.
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
