///|
/// Building an outgoing message.
///
/// Only what a watcher needs: one body part, an optional set of attachments,
/// UTF-8 everywhere, base64 for anything that is not plain ASCII. The output is
/// a complete RFC 5322 document with CRLF line endings; SMTP does the
/// dot-stuffing.

///|
pub struct Attachment {
  name : String
  mime : String
  data : Bytes
}

///|
pub struct Draft {
  from : String
  to : Array[String]
  cc : Array[String]
  bcc : Array[String]
  subject : String
  body : String
  html : Bool
  attachments : Array[Attachment]
}

///|
/// Everyone the message has to reach: `To`, `Cc` and `Bcc`. `Bcc` is kept out
/// of the headers but still gets an envelope recipient.
pub fn draft_recipients(draft : Draft) -> Array[String] {
  let out : Array[String] = []
  let seen : Array[String] = []
  for field in [draft.to, draft.cc, draft.bcc] {
    for address in field {
      // Some servers reject a repeated RCPT TO, and address case never
      // matters for delivery, so compare case-insensitively.
      let folded = trim(address).to_lower()
      if seen.contains(folded) {
        continue
      }
      seen.push(folded)
      out.push(trim(address))
    }
  }
  out
}

///|
let rfc5322_days : Array[String] = [
  "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat",
]

///|
let rfc5322_months : Array[String] = [
  "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
]

///|
fn pad2(value : Int64) -> String {
  if value < 10 {
    "0" + value.to_string()
  } else {
    value.to_string()
  }
}

///|
fn floor_div(a : Int64, b : Int64) -> Int64 {
  if a >= 0 {
    a / b
  } else {
    (a - b + 1) / b
  }
}

///|
/// Days since 1970-01-01 to a Gregorian date, by Howard Hinnant's `civil_from_days`.
fn civil_from_days(days : Int64) -> (Int64, Int64, Int64) {
  let z = days + 719468L
  let era = floor_div(z, 146097L)
  let doe = z - era * 146097L
  let yoe = (doe - doe / 1460L + doe / 36524L - doe / 146096L) / 365L
  let y = yoe + era * 400L
  let doy = doe - (365L * yoe + yoe / 4L - yoe / 100L)
  let mp = (5L * doy + 2L) / 153L
  let d = doy - (153L * mp + 2L) / 5L + 1L
  let m = if mp < 10L { mp + 3L } else { mp - 9L }
  (if m <= 2L { y + 1L } else { y }, m, d)
}

///|
/// Format a Unix timestamp the way a `Date:` header wants it.
///
/// Always UTC (`+0000`). Formatting in the sender's local time would need the
/// zone database, and a UTC date is what most mail tools print anyway.
pub fn rfc5322_date(now : Int64) -> String {
  let days = floor_div(now, 86400L)
  let seconds = now - days * 86400L
  let (year, month, day) = civil_from_days(days)
  let weekday = (days % 7L + 11L) % 7L
  let hour = seconds / 3600L
  let minute = seconds % 3600L / 60L
  let second = seconds % 60L
  rfc5322_days[weekday.to_int()] +
  ", " +
  pad2(day) +
  " " +
  rfc5322_months[(month - 1).to_int()] +
  " " +
  year.to_string() +
  " " +
  pad2(hour) +
  ":" +
  pad2(minute) +
  ":" +
  pad2(second) +
  " +0000"
}

///|
/// RFC 2047 encoded words for a header value with non-ASCII characters.
///
/// Each word is limited to 75 characters, which leaves 45 bytes of payload
/// after `=?UTF-8?B?` and `?=`. A word never splits a character, so the
/// decoder can put the value back together.
pub fn encode_header_text(text : String) -> String {
  let mut ascii = true
  for c in text {
    if c.to_int() > 0x7F {
      ascii = false
      break
    }
  }
  if ascii {
    return text
  }
  let words : Array[String] = []
  let chunk = StringBuilder()
  let mut chunk_bytes = 0
  for c in text {
    let size = @utf8.encode(c.to_string()).length()
    if chunk_bytes + size > 45 && chunk_bytes > 0 {
      words.push(
        "=?UTF-8?B?" + base64_encode(string_to_bytes(chunk.to_string())) + "?=",
      )
      chunk.reset()
      chunk_bytes = 0
    }
    chunk.write_char(c)
    chunk_bytes = chunk_bytes + size
  }
  if chunk_bytes > 0 {
    words.push(
      "=?UTF-8?B?" + base64_encode(string_to_bytes(chunk.to_string())) + "?=",
    )
  }
  words.join(" ")
}

///|
/// Fold a header at `;` or `,` once a line grows past 76 characters, the way a
/// mail client does for long recipient lists.
fn fold_header(name : String, value : String) -> String {
  let prefix = name + ": "
  if prefix.length() + value.length() <= 78 {
    return prefix + value
  }
  let out = StringBuilder()
  out.write_string(prefix)
  let mut column = prefix.length()
  let parts : Array[String] = []
  let current = StringBuilder()
  for c in value {
    current.write_char(c)
    if c == ',' || c == ';' {
      parts.push(current.to_string())
      current.reset()
    }
  }
  let tail = current.to_string()
  if tail != "" {
    parts.push(tail)
  }
  let mut first = true
  for part in parts {
    let piece = if first { part } else { part }
    if !first && column + trim(piece).length() > 76 {
      out.write_string("\r\n ")
      column = 1
    }
    out.write_string(piece)
    column = column + piece.length()
    first = false
  }
  out.to_string()
}

///|
/// Base64 folded into 76-column lines, as MIME wants it.
pub fn base64_body(data : Bytes) -> String {
  let encoded = base64_encode(data)
  let out = StringBuilder()
  let mut index = 0
  while index < encoded.length() {
    let end = if index + 76 < encoded.length() {
      index + 76
    } else {
      encoded.length()
    }
    out.write_string(encoded[index:end].to_owned())
    out.write_string("\r\n")
    index = end
  }
  out.to_string()
}

///|
/// A `Message-ID` that is unique enough without a random source: the timestamp
/// plus a caller-supplied token (the CLI uses bytes from `/dev/urandom`).
pub fn make_message_id(from : String, now : Int64, unique : String) -> String {
  let domain = match from.rev_find("@") {
    Some(index) => from[index + 1:].to_owned()
    None => "mails.local"
  }
  "<mails." + now.to_string() + "." + unique + "@" + domain + ">"
}

///|
fn mime_boundary(message_id : String, suffix : String) -> String {
  let token = StringBuilder()
  for c in message_id {
    let keep = (c >= 'a' && c <= 'z') ||
      (c >= 'A' && c <= 'Z') ||
      (c >= '0' && c <= '9')
    if keep {
      token.write_char(c)
    }
  }
  "mails-" + suffix + "-" + token.to_string()
}

///|
/// Render the message: headers, blank line, body.
///
/// `now` and `unique` are parameters rather than reads of the clock and the
/// random device so the result is testable and reproducible.
pub fn render_outgoing_message(
  draft : Draft,
  now : Int64,
  unique : String,
) -> String {
  let message_id = make_message_id(draft.from, now, unique)
  let subject = if trim(draft.subject) == "" {
    "(no subject)"
  } else {
    draft.subject
  }
  let headers = StringBuilder()
  headers.write_string(fold_header("From", draft.from) + "\r\n")
  if draft.to.length() > 0 {
    headers.write_string(fold_header("To", draft.to.join(", ")) + "\r\n")
  }
  if draft.cc.length() > 0 {
    headers.write_string(fold_header("Cc", draft.cc.join(", ")) + "\r\n")
  }
  // Bcc is deliberately absent: it only exists as an envelope recipient.
  headers.write_string("Subject: " + encode_header_text(subject) + "\r\n")
  headers.write_string("Date: " + rfc5322_date(now) + "\r\n")
  headers.write_string("Message-ID: " + message_id + "\r\n")
  headers.write_string("MIME-Version: 1.0\r\n")
  let body_text = trim_line_end(normalize_newlines(draft.body))
  let body_base64 = base64_body(string_to_bytes(body_text))
  if draft.attachments.length() == 0 {
    headers.write_string(
      "Content-Type: text/" +
      (if draft.html { "html" } else { "plain" }) +
      "; charset=utf-8\r\n",
    )
    headers.write_string("Content-Transfer-Encoding: base64\r\n")
    headers.write_string("\r\n")
    headers.write_string(body_base64)
  } else {
    let boundary = mime_boundary(message_id, "mix")
    headers.write_string(
      "Content-Type: multipart/mixed; boundary=\"" + boundary + "\"\r\n",
    )
    headers.write_string("\r\n")
    headers.write_string("--" + boundary + "\r\n")
    headers.write_string(
      "Content-Type: text/" +
      (if draft.html { "html" } else { "plain" }) +
      "; charset=utf-8\r\n",
    )
    headers.write_string("Content-Transfer-Encoding: base64\r\n\r\n")
    headers.write_string(body_base64)
    for attachment in draft.attachments {
      headers.write_string("--" + boundary + "\r\n")
      headers.write_string("Content-Type: " + attachment.mime + "\r\n")
      headers.write_string("Content-Transfer-Encoding: base64\r\n")
      headers.write_string(
        "Content-Disposition: attachment; filename=\"" +
        attachment_filename(attachment.name) +
        "\"\r\n\r\n",
      )
      headers.write_string(base64_body(attachment.data))
    }
    headers.write_string("--" + boundary + "--\r\n")
  }
  headers.to_string()
}

///|
/// A file name that is safe inside a quoted header parameter.
fn attachment_filename(name : String) -> String {
  let base = match name.rev_find("/") {
    Some(index) => name[index + 1:].to_owned()
    None => name
  }
  let out = StringBuilder()
  for c in base {
    if c == '"' || c == '\\' || c == '\r' || c == '\n' || c.to_int() > 0x7E {
      out.write_char('_')
    } else {
      out.write_char(c)
    }
  }
  out.to_string()
}

///|
/// Guess a content type from the file name. Everything unknown is
/// `application/octet-stream`, which every client can still save to disk.
pub fn guess_mime_type(name : String) -> String {
  let lower = name.to_lower()
  let base = match lower.rev_find(".") {
    Some(index) => lower[index + 1:].to_owned()
    None => ""
  }
  match base {
    "png" => "image/png"
    "jpg" | "jpeg" => "image/jpeg"
    "gif" => "image/gif"
    "webp" => "image/webp"
    "pdf" => "application/pdf"
    "txt" | "log" => "text/plain; charset=utf-8"
    "csv" => "text/csv; charset=utf-8"
    "json" => "application/json"
    "zip" => "application/zip"
    "gz" => "application/gzip"
    "html" | "htm" => "text/html; charset=utf-8"
    _ => "application/octet-stream"
  }
}
