///|
/// Browsing a mailbox: listing folders, listing messages and reading one.
///
/// This is the read side of the CLI, the counterpart of `watch`. It uses the
/// same `ImapClient`, so password, OAuth2 and TLS behaviour stay identical; the
/// only new protocol pieces are `LIST` and a header-only `UID FETCH`.
///
/// Nothing here runs a rule or writes a cursor: `ls` and `read` are for a human
/// at a terminal (or a script), and must not change what `watch` will do next.

///|
pub struct Folder {
  name : String
  delimiter : String
  attributes : Array[String]
}

///|
/// One row of `mails ls`: everything the envelope list shows, decoded.
pub struct Envelope {
  uid : String
  date : String
  from : String
  subject : String
  size : Int32
  seen : Bool
  flagged : Bool
}

///|
/// Parse one `LIST` line:
///
/// ```text
/// * LIST (\HasNoChildren) "/" "INBOX"
/// * LIST (\Noselect) "/" "[Gmail]/All Mail"
/// ```
pub fn parse_list_line(line : String) -> Folder? {
  let text = trim(line)
  if !text.has_prefix("* LIST") {
    return None
  }
  let rest = text[7:].to_owned()
  let mut index = 0
  let chars = rest.to_array()
  // Attributes: a parenthesised list, possibly empty.
  while index < chars.length() && chars[index] == ' ' {
    index = index + 1
  }
  let attributes : Array[String] = []
  if index < chars.length() && chars[index] == '(' {
    index = index + 1
    let current = StringBuilder()
    while index < chars.length() && chars[index] != ')' {
      if chars[index] == ' ' {
        if current.to_string() != "" {
          attributes.push(current.to_string())
          current.reset()
        }
      } else {
        current.write_char(chars[index])
      }
      index = index + 1
    }
    if current.to_string() != "" {
      attributes.push(current.to_string())
    }
    index = index + 1
  }
  // Delimiter: a quoted string or NIL.
  while index < chars.length() && chars[index] == ' ' {
    index = index + 1
  }
  let mut delimiter = ""
  if index < chars.length() && chars[index] == '"' {
    index = index + 1
    let value = StringBuilder()
    while index < chars.length() && chars[index] != '"' {
      if chars[index] == '\\' && index + 1 < chars.length() {
        index = index + 1
      }
      value.write_char(chars[index])
      index = index + 1
    }
    index = index + 1
    delimiter = value.to_string()
  } else {
    while index < chars.length() && chars[index] != ' ' {
      index = index + 1
    }
  }
  // Name: a quoted string or an atom.
  while index < chars.length() && chars[index] == ' ' {
    index = index + 1
  }
  if index >= chars.length() {
    return None
  }
  let name = if chars[index] == '"' {
    index = index + 1
    let value = StringBuilder()
    while index < chars.length() && chars[index] != '"' {
      if chars[index] == '\\' && index + 1 < chars.length() {
        index = index + 1
      }
      value.write_char(chars[index])
      index = index + 1
    }
    value.to_string()
  } else {
    let value = StringBuilder()
    while index < chars.length() {
      value.write_char(chars[index])
      index = index + 1
    }
    value.to_string()
  }
  Some({ name, delimiter, attributes, })
}

///|
/// Parse a `UID FETCH` reply that carries only a header literal.
///
/// The IMAP server returns one `* n FETCH (...)` line per message, with the
/// flags and the header as a literal.
pub fn parse_header_fetch(line : LogicalLine) -> Envelope? {
  if !line.text.to_upper().contains("FETCH") {
    return None
  }
  let uid = match token_after(line.text, "UID") {
    Some(value) => value
    None => return None
  }
  let size = match token_int(line.text, "RFC822.SIZE") {
    Some(value) => value
    None => 0
  }
  let lower = line.text.to_upper()
  let seen = lower.contains("\\SEEN")
  let flagged = lower.contains("\\FLAGGED")
  let header = match line.literals {
    [] => Bytes::new(0)
    [first, ..] => first
  }
  let headers = parse_headers(bytes_to_string_lossy(header))
  Some({
    uid,
    date: header_value(headers, "date"),
    from: decode_encoded_words(header_value(headers, "from")),
    subject: decode_encoded_words(header_value(headers, "subject")),
    size,
    seen,
    flagged,
  })
}

///|
/// `2026-10-27 10:02` from an RFC 5322 `Date:` value, or the raw value when it
/// cannot be understood.
///
/// The terminal is narrow, so a compact local-looking stamp beats the full
/// header. Only the `dd Mon yyyy hh:mm` shape Gmail, Outlook and friends emit is
/// understood; anything else is passed through so nothing is lost.
pub fn short_date(value : String) -> String {
  let text = trim(value)
  if text == "" {
    return ""
  }
  // Drop the leading weekday: "Mon, 27 Oct 2026 10:02:19 +0000"
  let mut rest = text
  match rest.find(",") {
    Some(index) => if index <= 4 { rest = trim(rest[index + 1:].to_owned()) }
    None => ()
  }
  let parts : Array[String] = []
  for piece in rest.split(" ") {
    let trimmed = trim(piece)
    if trimmed != "" {
      parts.push(trimmed)
    }
  }
  if parts.length() < 4 {
    return text
  }
  let day = parts[0]
  let month = parts[1]
  let year = parts[2]
  let time = parts[3]
  let hhmm = if time.length() >= 5 { time[0:5].to_owned() } else { time }
  let month_number = match month.to_lower() {
    "jan" => "01"
    "feb" => "02"
    "mar" => "03"
    "apr" => "04"
    "may" => "05"
    "jun" => "06"
    "jul" => "07"
    "aug" => "08"
    "sep" => "09"
    "oct" => "10"
    "nov" => "11"
    "dec" => "12"
    _ => ""
  }
  if month_number == "" {
    return text
  }
  let padded_day = if day.length() == 1 { "0" + day } else { day }
  year + "-" + month_number + "-" + padded_day + " " + hhmm
}

///|
/// Shorten `text` to `width` characters for the table, with an ellipsis.
pub fn fit_width(text : String, width : Int32) -> String {
  let collapsed = collapse_whitespace(text)
  if collapsed.char_length() <= width {
    return collapsed
  }
  if width <= 1 {
    return "…"
  }
  let out = StringBuilder()
  let mut count = 0
  for c in collapsed {
    if count >= width - 1 {
      break
    }
    out.write_char(c)
    count = count + 1
  }
  out.write_string("…")
  out.to_string()
}

///|
/// Pad `text` to `width` columns. Counts characters, not bytes, so a CJK
/// subject lines up with an ASCII one.
pub fn pad_to(text : String, width : Int32) -> String {
  let out = StringBuilder()
  out.write_string(text)
  let mut count = text.char_length()
  while count < width {
    out.write_char(' ')
    count = count + 1
  }
  out.to_string()
}

///|
/// The header row of `mails ls`.
pub fn envelope_table_header(
  uid_width : Int32,
  from_width : Int32,
  subject_width : Int32,
) -> String {
  pad_to("UID", uid_width) +
  "  " +
  pad_to("DATE", 16) +
  "  " +
  pad_to("FROM", from_width) +
  "  " +
  // The marker column of `envelope_table_row`.
  "  " +
  pad_to("SUBJECT", subject_width)
}

///|
/// One row of `mails ls`.
pub fn envelope_table_row(
  envelope : Envelope,
  uid_width : Int32,
  from_width : Int32,
  subject_width : Int32,
) -> String {
  let mark = if envelope.seen { " " } else { "*" }
  pad_to(envelope.uid, uid_width) +
  "  " +
  pad_to(short_date(envelope.date), 16) +
  "  " +
  pad_to(fit_width(envelope.from, from_width), from_width) +
  "  " +
  mark +
  " " +
  fit_width(envelope.subject, subject_width)
}

///|
/// Render the whole table, newest first, which is the order readers expect.
fn trim_trailing_spaces(text : String) -> String {
  let chars = text.to_array()
  let mut end = chars.length()
  while end > 0 && chars[end - 1] == ' ' {
    end = end - 1
  }
  let out = StringBuilder()
  for index in 0..<end {
    out.write_char(chars[index])
  }
  out.to_string()
}

///|
/// Render the whole table, newest first, which is the order readers expect.
pub fn render_envelope_table(envelopes : Array[Envelope]) -> String {
  if envelopes.length() == 0 {
    return ""
  }
  let mut uid_width = 3
  for envelope in envelopes {
    if envelope.uid.length() > uid_width {
      uid_width = envelope.uid.length()
    }
  }
  let from_width = 24
  let subject_width = 60
  let lines : Array[String] = [
    envelope_table_header(uid_width, from_width, subject_width),
  ]
  for envelope in envelopes {
    lines.push(
      envelope_table_row(envelope, uid_width, from_width, subject_width),
    )
  }
  // The last column is not padded, so drop the padding the header carries:
  // trailing spaces only make `mails ls` noisy in a pipe.
  let cleaned : Array[String] = []
  for line in lines {
    cleaned.push(trim_trailing_spaces(line))
  }
  cleaned.join("\n")
}

///|
/// `LIST "" "*"`: every folder the server knows about, with modified UTF-7
/// names decoded so `[Gmail]/&XfJT0ZAB-` prints as `[Gmail]/Sent Mail`.
pub async fn ImapClient::list_folders(client : ImapClient) -> Array[Folder] {
  let reply = execute(client, "LIST \"\" \"*\"")
  let out : Array[Folder] = []
  for line in reply.lines {
    match parse_list_line(line.text) {
      Some(folder) =>
        out.push({ ..folder, name: decode_modified_utf7(folder.name), })
      None => ()
    }
  }
  out
}

///|
/// Sort UID strings numerically and keep the newest `limit`.
fn newest_uids(uids : Array[String], limit : Int32) -> Array[String] {
  let values : Array[Int32] = []
  for raw in uids {
    let value = @string.parse_int(raw) catch { _ => -1 }
    if value > 0 {
      values.push(value)
    }
  }
  let mut index = 0
  while index < values.length() {
    let mut best = index
    let mut scan = index + 1
    while scan < values.length() {
      if values[scan] < values[best] {
        best = scan
      }
      scan = scan + 1
    }
    if best != index {
      let tmp = values[index]
      values[index] = values[best]
      values[best] = tmp
    }
    index = index + 1
  }
  let out : Array[String] = []
  let mut position = values.length() - 1
  while position >= 0 && out.length() < limit {
    out.push(values[position].to_string())
    position = position - 1
  }
  out
}

///|
/// The messages of the selected mailbox, newest first.
///
/// One `UID SEARCH` to learn the UIDs, then one header-only `UID FETCH` per
/// batch of 50. Only `Date`, `From` and `Subject` are requested, so listing a
/// large mailbox stays cheap.
pub async fn ImapClient::list_envelopes(
  client : ImapClient,
  limit : Int32,
  unread_only : Bool,
) -> Array[Envelope] {
  let all = if unread_only {
    let reply = execute(client, "UID SEARCH UNSEEN")
    let out : Array[String] = []
    for line in reply_texts(reply) {
      if line.to_upper().has_prefix("* SEARCH") {
        let parts = tokens(line)
        let mut index = 2
        while index < parts.length() {
          out.push(parts[index])
          index = index + 1
        }
      }
    }
    out
  } else {
    client.search_uids(1)
  }
  let wanted = newest_uids(all, limit)
  let out : Array[Envelope] = []
  let mut start = 0
  while start < wanted.length() {
    let end = if start + 50 < wanted.length() {
      start + 50
    } else {
      wanted.length()
    }
    let batch = wanted[start:end]
    let reply = execute(
      client,
      "UID FETCH " +
      batch.join(",") +
      " (UID FLAGS RFC822.SIZE BODY.PEEK[HEADER.FIELDS (DATE FROM SUBJECT)])",
    )
    for line in reply.lines {
      match parse_header_fetch(line) {
        Some(envelope) => out.push(envelope)
        None => ()
      }
    }
    start = end
  }
  out
}

///|
/// The raw message, headers included, for `mails read --raw` and for piping to
/// another tool.
pub async fn ImapClient::fetch_raw(client : ImapClient, uid : String) -> Bytes? {
  let reply = execute(client, "UID FETCH " + uid + " (BODY.PEEK[])")
  for line in reply.lines {
    if line.text.to_upper().contains("FETCH") && line.literals.length() > 0 {
      return Some(line.literals[0])
    }
  }
  None
}
