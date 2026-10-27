///| RFC 5322 / MIME parsing: just enough to extract a subject and readable
/// body text from what IMAP hands us.
///
/// Messages are fetched as `BODY.PEEK[HEADER]` plus `BODY.PEEK[TEXT]`, so the
/// parser deals with header bytes and body bytes separately. Multipart bodies
/// are walked recursively; `text/plain` is preferred, `text/html` is stripped
/// of tags when no plain part exists, and attachments are skipped.

///|
pub struct MailMessage {
  uid : String
  mailbox : String
  subject : String
  from : String
  to : String
  date : String
  message_id : String
  body : String
  raw_bytes : Int32
}

///|
fn header_value(headers : Array[(String, String)], name : String) -> String {
  let wanted = name.to_lower()
  let mut found = ""
  for pair in headers {
    if pair.0 == wanted {
      found = pair.1
    }
  }
  found
}

///|
fn header_value_all(
  headers : Array[(String, String)],
  name : String,
) -> Array[String] {
  let wanted = name.to_lower()
  let out : Array[String] = []
  for pair in headers {
    if pair.0 == wanted {
      out.push(pair.1)
    }
  }
  out
}

///|
fn hex_nibble(c : Char) -> Int32? {
  if c >= '0' && c <= '9' {
    Some(c.to_int() - '0'.to_int())
  } else if c >= 'a' && c <= 'f' {
    Some(c.to_int() - 'a'.to_int() + 10)
  } else if c >= 'A' && c <= 'F' {
    Some(c.to_int() - 'A'.to_int() + 10)
  } else {
    None
  }
}

///|
fn decode_quoted_printable_bytes(
  text : StringView,
  underscore_is_space : Bool,
) -> Bytes {
  let out : Array[Byte] = []
  let chars = text.to_array()
  let mut index = 0
  while index < chars.length() {
    let c = chars[index]
    if c == '=' {
      if index + 2 < chars.length() {
        match (hex_nibble(chars[index + 1]), hex_nibble(chars[index + 2])) {
          (Some(high), Some(low)) => {
            out.push(((high * 16 + low) & 0xFF).to_byte())
            index = index + 3
            continue
          }
          _ => ()
        }
      }
      index = index + 1
    } else if c == '_' && underscore_is_space {
      out.push(b' ')
      index = index + 1
    } else if c == '\r' || c == '\n' {
      index = index + 1
    } else {
      for byte in @utf8.encode(c.to_string()) {
        out.push(byte)
      }
      index = index + 1
    }
  }
  Bytes::from_array(out[:])
}

///|
fn decode_latin1(data : Bytes) -> String {
  let out = StringBuilder()
  for byte in data {
    out.write_char(byte.to_int().unsafe_to_char())
  }
  out.to_string()
}

///|
/// Decode bytes in the named charset well enough for keyword matching.
pub fn decode_charset(data : Bytes, charset : String) -> String {
  match charset.to_lower() {
    "iso-8859-1" | "latin1" | "latin-1" | "windows-1252" => decode_latin1(data)
    "us-ascii" | "ascii" => bytes_to_string_lossy(data)
    _ => bytes_to_string_lossy(data)
  }
}

///|
/// Decode RFC 2047 encoded words (`=?utf-8?B?...?=`) in a header value.
pub fn decode_encoded_words(value : String) -> String {
  let out = StringBuilder()
  let mut rest = value
  let mut attempts = 0
  while attempts < 64 {
    attempts = attempts + 1
    match rest.find("=?") {
      None => {
        out.write_string(rest)
        break
      }
      Some(start) => {
        out.write_string(rest[0:start].to_owned())
        let after = rest[start + 2:].to_owned()
        match after.find("?") {
          None => {
            out.write_string(rest[start:].to_owned())
            break
          }
          Some(charset_end) => {
            let charset = after[0:charset_end].to_owned()
            let after2 = after[charset_end + 1:].to_owned()
            match after2.find("?") {
              None => {
                out.write_string(rest[start:].to_owned())
                break
              }
              Some(encoding_end) => {
                let encoding = after2[0:encoding_end].to_owned()
                let after3 = after2[encoding_end + 1:].to_owned()
                match after3.find("?=") {
                  None => {
                    out.write_string(rest[start:].to_owned())
                    break
                  }
                  Some(text_end) => {
                    let encoded = after3[0:text_end].to_owned()
                    let decoded = match encoding.to_lower() {
                      "b" =>
                        @base64.decode_lossy(encoded, ignore_whitespace=true)
                      "q" => decode_quoted_printable_bytes(encoded, true)
                      _ => string_to_bytes(encoded)
                    }
                    out.write_string(decode_charset(decoded, charset))
                    rest = after3[text_end + 2:].to_owned()
                  }
                }
              }
            }
          }
        }
      }
    }
  }
  out.to_string()
}

///|
/// Split raw header bytes into unfolded `(lowercase-name, value)` pairs.
pub fn parse_headers(raw : String) -> Array[(String, String)] {
  let headers : Array[(String, String)] = []
  let mut current_name = ""
  let mut current_value = ""
  let mut have_current = false
  for raw_line in raw.split("\n") {
    let mut line = raw_line.to_owned()
    if line.has_suffix("\r") {
      line = line[0:line.length() - 1].to_owned()
    }
    if line == "" {
      continue
    }
    let first = if line.length() > 0 { line[0:1] } else { "" }
    if (first == " " || first == "\t") && have_current {
      current_value = current_value + " " + trim(line)
      continue
    }
    if have_current {
      headers.push((current_name, trim(current_value)))
      have_current = false
    }
    match line.find(":") {
      Some(index) => {
        current_name = trim(line[0:index].to_owned()).to_lower()
        current_value = trim(line[index + 1:].to_owned())
        have_current = true
      }
      None => ()
    }
  }
  if have_current {
    headers.push((current_name, trim(current_value)))
  }
  headers
}

///|
/// Parse `Content-Type`-style values into a lowercased type plus parameters.
pub fn parse_content_type(value : String) -> (String, Array[(String, String)]) {
  let parts : Array[String] = []
  for part in value.split(";") {
    parts.push(part.to_owned())
  }
  let media_type = if parts.length() > 0 {
    trim(parts[0]).to_lower()
  } else {
    "text/plain"
  }
  let params : Array[(String, String)] = []
  let mut index = 1
  while index < parts.length() {
    let part = parts[index]
    match part.find("=") {
      Some(eq) => {
        let key = trim(part[0:eq].to_owned()).to_lower()
        let mut raw = trim(part[eq + 1:].to_owned())
        if raw.length() >= 2 {
          let first = raw[0:1]
          let last = raw[raw.length() - 1:]
          if (first == "\"" && last == "\"") || (first == "'" && last == "'") {
            raw = raw[1:raw.length() - 1].to_owned()
          }
        }
        params.push((key, raw))
      }
      None => ()
    }
    index = index + 1
  }
  (media_type, params)
}

///|
fn param_value(params : Array[(String, String)], name : String) -> String? {
  let mut found : String? = None
  for pair in params {
    if pair.0 == name {
      found = Some(pair.1)
    }
  }
  found
}

///|
fn decode_transfer(body : String, encoding : String) -> Bytes {
  match encoding.to_lower() {
    "base64" => {
      let compact = StringBuilder()
      for c in body {
        if c != ' ' && c != '\r' && c != '\n' && c != '\t' {
          compact.write_char(c)
        }
      }
      @base64.decode_lossy(compact.to_string())
    }
    "quoted-printable" => decode_quoted_printable_bytes(body, false)
    _ => string_to_bytes(body)
  }
}

///|
fn strip_html(html : String) -> String {
  let out = StringBuilder()
  let mut index = 0
  let chars = html.to_array()
  let mut in_tag = false
  let mut in_script = false
  while index < chars.length() {
    let c = chars[index]
    if c == '<' {
      let rest : Array[Char] = []
      let mut peek = index
      while peek < chars.length() && rest.length() < 8 {
        rest.push(chars[peek])
        peek = peek + 1
      }
      let tag = String::from_array(rest[:]).to_lower()
      if tag.has_prefix("<script") || tag.has_prefix("<style") {
        in_script = true
      }
      if tag.has_prefix("</script") || tag.has_prefix("</style") {
        in_script = false
        in_tag = true
        index = index + 1
        continue
      }
      if in_script {
        index = index + 1
        continue
      }
      if c == '<' {
        in_tag = true
      }
      index = index + 1
      continue
    }
    if c == '>' && in_tag {
      in_tag = false
      index = index + 1
      continue
    }
    if !in_tag && !in_script {
      if c == '&' {
        // Decode a handful of common entities; unknown ones stay literal.
        let tail : Array[Char] = []
        let mut peek = index
        while peek < chars.length() && tail.length() < 10 {
          tail.push(chars[peek])
          peek = peek + 1
          if chars[peek - 1] == ';' {
            break
          }
        }
        let entity = String::from_array(tail[:])
        if entity.has_prefix("&amp;") {
          out.write_char('&')
          index = index + 5
          continue
        } else if entity.has_prefix("&lt;") {
          out.write_char('<')
          index = index + 4
          continue
        } else if entity.has_prefix("&gt;") {
          out.write_char('>')
          index = index + 4
          continue
        } else if entity.has_prefix("&quot;") {
          out.write_char('"')
          index = index + 6
          continue
        } else if entity.has_prefix("&nbsp;") {
          out.write_char(' ')
          index = index + 6
          continue
        } else if entity.has_prefix("&#") {
          match entity.find(";") {
            Some(semi) => {
              let code = @string.parse_int(entity[2:semi].to_owned()) catch {
                _ => -1
              }
              if code > 0 {
                out.write_char(code.unsafe_to_char())
                index = index + semi + 1
                continue
              }
            }
            None => ()
          }
        }
      }
      out.write_char(c)
    }
    index = index + 1
  }
  out.to_string()
}

///|
pub struct MimeText {
  mut plain : String
  mut html : String
}

///|
fn walk_mime(
  headers : Array[(String, String)],
  body : String,
  depth : Int32,
  text : MimeText,
) -> Unit {
  if depth > 12 {
    return
  }
  let content_type = match header_value(headers, "content-type") {
    "" => "text/plain"
    value => value
  }
  let (media_type, params) = parse_content_type(content_type)
  if media_type.has_prefix("multipart/") {
    match param_value(params, "boundary") {
      Some(boundary) if boundary != "" => {
        let marker = "--" + boundary
        for raw_part in body.split(marker) {
          let part = raw_part.to_owned()
          let trimmed = trim(part)
          if trimmed == "" || trimmed == "--" || trimmed.has_prefix("--") {
            continue
          }
          let content = if part.has_prefix("\r\n") {
            part[2:].to_owned()
          } else if part.has_prefix("\n") {
            part[1:].to_owned()
          } else {
            part
          }
          let (part_headers, part_body) = split_header_body(content)
          walk_mime(part_headers, part_body, depth + 1, text)
        }
      }
      _ => ()
    }
    return
  }
  let disposition = parse_content_type(
      header_value(headers, "content-disposition"),
    ).0
  if disposition == "attachment" {
    return
  }
  let encoding = header_value(headers, "content-transfer-encoding")
  let charset = match param_value(params, "charset") {
    Some(value) => value
    None => "utf-8"
  }
  if media_type == "text/plain" {
    let bytes = decode_transfer(body, encoding)
    text.plain = text.plain + decode_charset(bytes, charset) + "\n"
  } else if media_type == "text/html" {
    let bytes = decode_transfer(body, encoding)
    text.html = text.html + strip_html(decode_charset(bytes, charset)) + "\n"
  }
}

///|
/// Split a raw MIME entity into parsed headers and a body string.
pub fn split_header_body(raw : String) -> (Array[(String, String)], String) {
  let separator = match raw.find("\r\n\r\n") {
    Some(index) => Some((index, 4))
    None =>
      match raw.find("\n\n") {
        Some(index) => Some((index, 2))
        None => None
      }
  }
  match separator {
    Some((index, width)) =>
      (parse_headers(raw[0:index].to_owned()), raw[index + width:].to_owned())
    None => ([], raw)
  }
}

///|
/// Extract readable text from a body plus its already-parsed headers.
///
/// IMAP returns the top-level headers (`HEADER`) and the body (`TEXT`)
/// separately, and `TEXT` does not repeat the top-level `Content-Type`, so the
/// caller has to pass the header list in for multipart mail to be recognised.
pub fn message_body_text_with_headers(
  headers : Array[(String, String)],
  raw_body : Bytes,
) -> String {
  let text : MimeText = { plain: "", html: "", }
  walk_mime(headers, bytes_to_string_lossy(raw_body), 0, text)
  let plain = collapse_whitespace(text.plain)
  if !is_blank(plain) {
    plain
  } else {
    collapse_whitespace(text.html)
  }
}

///|
/// Extract the readable text of a standalone MIME entity.
pub fn message_body_text(raw_body : Bytes) -> String {
  let raw = bytes_to_string_lossy(raw_body)
  let (headers, body) = split_header_body(raw)
  message_body_text_with_headers(headers, string_to_bytes(body))
}

///|
/// Build a message from the fetched header and body literals.
pub fn build_message(
  mailbox : String,
  uid : String,
  raw_size : Int32,
  header : Bytes,
  body : Bytes,
) -> MailMessage {
  let headers = parse_headers(bytes_to_string_lossy(header))
  let subject = decode_encoded_words(header_value(headers, "subject"))
  let from = decode_encoded_words(header_value(headers, "from"))
  let to_header = header_value_all(headers, "to")
  let to = if to_header.length() > 0 {
    decode_encoded_words(to_header[0])
  } else {
    ""
  }
  let date = header_value(headers, "date")
  let message_id = header_value(headers, "message-id")
  {
    uid,
    mailbox,
    subject: collapse_whitespace(subject),
    from: collapse_whitespace(from),
    to: collapse_whitespace(to),
    date,
    message_id,
    body: message_body_text_with_headers(headers, body),
    raw_bytes: raw_size,
  }
}
