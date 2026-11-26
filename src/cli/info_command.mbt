///|
/// Run `info`: report the persisted header without loading the index.
///
/// The default path reads only the header and section table, so it stays fast
/// on a large database. `--verify` additionally checks the full-file CRC and
/// recomputes every derived structure to prove semantic consistency.
async fn run_info(invocation : Invocation) -> CliResult {
  let database = match database_path(invocation) {
    Ok(path) => path
    Err(message) => return Failure(message)
  }
  let verify = flag_set(invocation.matches, "verify")
  let loaded : Result[@index.DbInfo, String] = Ok(
    @index.read_database_info(database, verify~),
  ) catch {
    err => Err("error: \{err.message()}")
  }
  let info = match loaded {
    Ok(info) => info
    Err(message) => return Failure(message)
  }
  let out = StringBuilder()
  out.write_string("database: \{database}\n")
  out.write_string("format: MSDB \{info.format_major}.\{info.format_minor}\n")
  out.write_string("built: \{info.built_at}\n")
  out.write_string("roots: \{info.root_count}\n")
  out.write_string("folders: \{info.folder_count}\n")
  out.write_string("files: \{info.file_count}\n")
  out.write_string("names: \{info.name_count}\n")
  out.write_string("size: \{info.file_size} bytes\n")
  if info.trigram_count > 0 {
    out.write_string("trigram: \{info.trigram_count} keys\n")
  } else {
    out.write_string("trigram: disabled\n")
  }
  out.write_string(
    "checksum: \{if verify { "verified" } else { "metadata" }}\n",
  )
  let parts : Array[String] = []
  for section in info.sections {
    parts.push("\{section.name}=\{section.length}")
  }
  out.write_string("sections: \{parts.join(" ")}")
  Success(text_line(out.to_string()))
}
