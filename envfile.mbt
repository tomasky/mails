///| A minimal `.env` reader and writer.
///
/// Only the shape the tool needs is supported: `KEY=VALUE` lines, optional
/// `export ` prefixes, `#` comments and single or double quotes around a
/// value. Everything else in the file is preserved when it is rewritten.

///|
pub struct EnvFile {
  path : String
  keys : Array[String]
  values : Array[String]
}

///|
pub fn EnvFile::get(self : EnvFile, name : String) -> String? {
  let mut found : String? = None
  let mut index = 0
  while index < self.keys.length() {
    if self.keys[index] == name {
      found = Some(self.values[index])
    }
    index = index + 1
  }
  found
}

///|
fn unquote_env_value(raw : String) -> String {
  let text = trim(raw)
  if text.length() >= 2 {
    let first = text[0:1]
    let last = text[text.length() - 1:]
    if (first == "\"" && last == "\"") || (first == "'" && last == "'") {
      return text[1:text.length() - 1].to_owned()
    }
  }
  // Inline comments: `KEY=value # note` keeps `value`.
  match text.find(" #") {
    Some(index) => trim(text[0:index].to_owned())
    None => text
  }
}

///|
fn parse_env_text(path : String, source : String) -> EnvFile {
  let keys : Array[String] = []
  let values : Array[String] = []
  for raw_line in source.split("\n") {
    let mut line = trim(raw_line)
    if line == "" || line.has_prefix("#") {
      continue
    }
    if line.has_prefix("export ") {
      line = trim(line[7:].to_owned())
    }
    match line.find("=") {
      Some(index) => {
        let key = trim(line[0:index].to_owned())
        if key != "" {
          keys.push(key)
          values.push(unquote_env_value(line[index + 1:].to_owned()))
        }
      }
      None => ()
    }
  }
  { path, keys, values, }
}

///|
/// Read a `.env` file. A missing file yields an empty environment.
pub async fn load_env_file(path : String) -> EnvFile raise MailsError {
  let exists = @fs.exists(path) catch { _ => false }
  if !exists {
    return { path, keys: [], values: [], }
  }
  let data = @fs.read_file(path) catch {
    _ => raise MailsError("cannot read the env file " + path)
  }
  let source = data.text() catch {
    _ => raise MailsError("the env file " + path + " is not valid UTF-8")
  }
  parse_env_text(path, source)
}

///|
fn env_quote_value(value : String) -> String {
  let mut needs_quotes = value == ""
  for c in value {
    if c == ' ' || c == '\t' || c == '"' || c == '\'' || c == '#' || c == '\\' {
      needs_quotes = true
    }
  }
  if !needs_quotes {
    return value
  }
  let out = StringBuilder()
  out.write_char('"')
  for c in value {
    if c == '"' || c == '\\' {
      out.write_char('\\')
    }
    out.write_char(c)
  }
  out.write_char('"')
  out.to_string()
}

///|
/// Set (or add) a variable in a `.env` file, preserving every other line.
///
/// The file is created with mode `0600` and existing permissions are tightened,
/// because the encryption key must never be group- or world-readable.
pub async fn set_env_var(
  path : String,
  name : String,
  value : String,
) -> Unit raise MailsError {
  let lines : Array[String] = []
  let exists = @fs.exists(path) catch { _ => false }
  if exists {
    let data = @fs.read_file(path) catch {
      _ => raise MailsError("cannot read the env file " + path)
    }
    let source = data.text() catch {
      _ => raise MailsError("the env file " + path + " is not valid UTF-8")
    }
    if source != "" {
      for line in source.split("\n") {
        lines.push(line.to_owned())
      }
      if lines.length() > 0 && lines[lines.length() - 1] == "" {
        let _ = lines.pop()
      }
    }
  }
  let rendered = name + "=" + env_quote_value(value)
  let mut replaced = false
  let out : Array[String] = []
  for line in lines {
    let stripped = trim(line)
    let bare = if stripped.has_prefix("export ") {
      trim(stripped[7:].to_owned())
    } else {
      stripped
    }
    let matches_key = match bare.find("=") {
      Some(index) => trim(bare[0:index].to_owned()) == name
      None => false
    }
    if matches_key {
      if !replaced {
        out.push(rendered)
        replaced = true
      }
    } else {
      out.push(line)
    }
  }
  if !replaced {
    out.push(rendered)
  }
  let text = StringBuilder()
  for line in out {
    text.write_string(line)
    text.write_char('\n')
  }
  @fs.write_file(
    path,
    text.to_string(),
    create_mode=CreateOrTruncate,
    permission=0o600,
  ) catch {
    _ => raise MailsError("cannot write the env file " + path)
  }
  @fs.chmod(path, 0o600) catch {
    _ => ()
  }
}

///|
/// Whether an environment variable name looks like it holds a secret.
fn is_secret_name(name : String) -> Bool {
  let upper = name.to_upper()
  upper.contains("KEY") ||
  upper.contains("SECRET") ||
  upper.contains("TOKEN") ||
  upper.contains("PASSWORD")
}

///|
/// Render the contents of an env file for `mails env --show` style output.
pub fn render_env_for_display(env : EnvFile, reveal : Bool) -> String {
  let out = StringBuilder()
  let mut index = 0
  while index < env.keys.length() {
    out.write_string(env.keys[index])
    out.write_char('=')
    if reveal || !is_secret_name(env.keys[index]) {
      out.write_string(env.values[index])
    } else {
      out.write_string("***")
    }
    out.write_char('\n')
    index = index + 1
  }
  out.to_string()
}
