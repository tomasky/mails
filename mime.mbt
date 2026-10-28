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
/// Split `data` on every occurrence of `separator`, returning the pieces.
fn bytes_split(data : Bytes, separator : Bytes) -> Array[Bytes] {
  let out : Array[Bytes] = []
  let mut start = 0
  while start <= data.length() {
    let found = data[start:].find(separator[:])
    match found {
      Some(offset) => {
        out.push(data[start:start + offset].to_owned())
        start = start + offset + separator.length()
      }
      None => {
        out.push(data[start:].to_owned())
        break
      }
    }
  }
  out
}

///|
/// Decode a quoted-printable body directly on bytes.
///
/// The MIME walker used to go through a lossy `String` first, which destroyed
/// every byte above 0x7F and turned GBK mail into U+FFFD before the charset
/// decoder ever saw it.
fn decode_quoted_printable_data(data : Bytes) -> Bytes {
  let out : Array[Byte] = []
  let mut index = 0
  while index < data.length() {
    let value = data[index].to_int()
    if value == 0x3D {
      if index + 2 < data.length() {
        match
          (
            hex_nibble(data[index + 1].to_int().unsafe_to_char()),
            hex_nibble(data[index + 2].to_int().unsafe_to_char()),
          ) {
          (Some(high), Some(low)) => {
            out.push(((high * 16 + low) & 0xFF).to_byte())
            index = index + 3
            continue
          }
          _ => ()
        }
      }
      index = index + 1
    } else if value == 0x0D || value == 0x0A {
      index = index + 1
    } else {
      out.push(data[index])
      index = index + 1
    }
  }
  Bytes::from_array(out[:])
}

///|
/// Charset of a body part: the `charset` parameter when the headers carry one,
/// otherwise the one an HTML `<meta>` tag declares.
///
/// Chinese providers routinely leave the charset out of the MIME headers and
/// only declare it inside the HTML, which used to decode as UTF-8 mojibake.
fn charset_of(declared : String?, bytes : Bytes, is_html : Bool) -> String {
  match declared {
    Some(value) => value
    None =>
      if is_html {
        match sniff_html_charset(bytes) {
          Some(value) => value
          None => "utf-8"
        }
      } else {
        "utf-8"
      }
  }
}

///|
/// Read `charset=` out of the first few hundred bytes of an HTML document.
fn sniff_html_charset(bytes : Bytes) -> String? {
  let limit = if bytes.length() < 4096 { bytes.length() } else { 4096 }
  let head = bytes_to_string_lossy(bytes[0:limit].to_owned()).to_lower()
  // Only trust a declaration that mentions <meta>, so a stray "charset=" in
  // the text of a plain-looking document is ignored.
  if !head.contains("<meta") {
    return None
  }
  let mut search = head
  let mut attempts = 0
  while attempts < 8 {
    attempts = attempts + 1
    match search.find("charset=") {
      None => return None
      Some(index) => {
        let after = search[index + "charset=".length():].to_owned()
        // The value is often quoted: `charset="gb2312"`.
        let mut body = after
        while body.length() > 0 && (body[0] == ' ' || body[0] == '\t') {
          body = body[1:].to_owned()
        }
        if body.length() > 0 && (body[0] == '"' || body[0] == '\'') {
          body = body[1:].to_owned()
        }
        let name = StringBuilder()
        for c in body {
          let stop = c == '"' ||
            c == '\'' ||
            c == ';' ||
            c == ' ' ||
            c == '\t' ||
            c == '\r' ||
            c == '\n' ||
            c == '>'
          if stop {
            break
          }
          name.write_char(c)
        }
        let candidate = trim(name.to_string())
        if candidate != "" && candidate.length() <= 40 {
          return Some(candidate)
        }
        search = after
      }
    }
  }
  None
}

///|
fn decode_transfer(body : Bytes, encoding : String) -> Bytes {
  match encoding.to_lower() {
    "base64" =>
      // Base64 payloads are ASCII, so the lossy read is harmless here.
      @base64.decode_lossy(bytes_to_string_lossy(body), ignore_whitespace=true)
    "quoted-printable" => decode_quoted_printable_data(body)
    _ => body
  }
}

///|
/// Block-level tags whose boundaries end a line in the plain text rendering of
/// an HTML message. The source layout of an HTML mail carries no meaning, so the
/// tags are what tell the reader where one paragraph stops and the next starts.
fn html_line_break_tag(tag : String) -> Bool {
  let names = [
    "br", "hr", "p", "div", "li", "tr", "h1", "h2", "h3", "h4", "h5", "h6", "pre",
    "blockquote", "section", "article", "table", "ul", "ol",
  ]
  // Compare the whole tag name: `has_prefix("<p")` would also fire for
  // `<param>`, `<picture>` or `<link>` and inject breaks where the message has
  // none.
  let mut start = 1
  if tag.length() > 1 && tag[1] == '/' {
    start = 2
  }
  let mut end = start
  while end < tag.length() {
    let c = tag[end]
    let is_name = (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9')
    if !is_name {
      break
    }
    end = end + 1
  }
  if end == start {
    return false
  }
  let name = tag[start:end].to_owned()
  names.contains(name)
}

///|
fn strip_html(html : String) -> String {
  // Characters are collected into an array instead of written straight into a
  // StringBuilder so that HTML whitespace can be squeezed the way a browser
  // does: runs of spaces and tabs become one space, spaces next to a line break
  // disappear, and the block tags below supply the line breaks rather than the
  // source layout.
  let out : Array[Char] = []
  let push_space = () => {
    if out.length() > 0 {
      let last = out[out.length() - 1]
      if last != ' ' && last != '\n' {
        out.push(' ')
      }
    }
  }
  let push_break = () => if out.length() > 0 { out.push('\n') }
  let mut index = 0
  let chars = html.to_array()
  let mut in_tag = false
  let mut in_script = false
  while index < chars.length() {
    let c = chars[index]
    if c == '<' {
      let rest : Array[Char] = []
      let mut peek = index
      while peek < chars.length() && rest.length() < 16 {
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
      if html_line_break_tag(tag) {
        push_break()
      }
      in_tag = true
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
          out.push('&')
          index = index + 5
          continue
        } else if entity.has_prefix("&lt;") {
          out.push('<')
          index = index + 4
          continue
        } else if entity.has_prefix("&gt;") {
          out.push('>')
          index = index + 4
          continue
        } else if entity.has_prefix("&quot;") {
          out.push('"')
          index = index + 6
          continue
        } else if entity.has_prefix("&nbsp;") {
          push_space()
          index = index + 6
          continue
        } else if entity.has_prefix("&#") {
          match entity.find(";") {
            Some(semi) => {
              let code = @string.parse_int(entity[2:semi].to_owned()) catch {
                _ => -1
              }
              if code > 0 {
                out.push(code.unsafe_to_char())
                index = index + semi + 1
                continue
              }
            }
            None => ()
          }
        }
      }
      if c == ' ' || c == '\t' || c == '\n' || c == '\r' {
        push_space()
      } else {
        out.push(c)
      }
    }
    index = index + 1
  }
  String::from_array(out[:])
}

///|
pub struct MimeText {
  mut plain : String
  mut html : String
}

///|
fn walk_mime(
  headers : Array[(String, String)],
  body : Bytes,
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
        let marker = string_to_bytes("--" + boundary)
        for raw_part in bytes_split(body, marker) {
          if raw_part.length() == 0 {
            continue
          }
          if raw_part.has_prefix(string_to_bytes("--")) {
            continue
          }
          let content = if raw_part.has_prefix(string_to_bytes("\r\n")) {
            raw_part[2:].to_owned()
          } else if raw_part.has_prefix(string_to_bytes("\n")) {
            raw_part[1:].to_owned()
          } else {
            raw_part
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
  let declared = param_value(params, "charset")
  if media_type == "text/plain" {
    let bytes = decode_transfer(body, encoding)
    text.plain = text.plain +
      decode_charset(bytes, charset_of(declared, bytes, false)) +
      "\n"
  } else if media_type == "text/html" {
    let bytes = decode_transfer(body, encoding)
    text.html = text.html +
      strip_html(decode_charset(bytes, charset_of(declared, bytes, true))) +
      "\n"
  }
}

///|
/// Split a raw MIME entity into parsed headers and a body string.
pub fn split_header_body(raw : Bytes) -> (Array[(String, String)], Bytes) {
  let separator = match raw.find(string_to_bytes("\r\n\r\n")) {
    Some(index) => Some((index, 4))
    None =>
      match raw.find(string_to_bytes("\n\n")) {
        Some(index) => Some((index, 2))
        None => None
      }
  }
  match separator {
    Some((index, width)) =>
      (
        parse_headers(bytes_to_string_lossy(raw[0:index].to_owned())),
        raw[index + width:].to_owned(),
      )
    None => ([], raw)
  }
}

///|
/// Normalize CRLF and lone CR line endings to LF.
fn normalize_newlines(text : String) -> String {
  let out = StringBuilder()
  let chars = text.to_array()
  let mut index = 0
  while index < chars.length() {
    let c = chars[index]
    if c == '\r' {
      out.write_char('\n')
      if index + 1 < chars.length() && chars[index + 1] == '\n' {
        index = index + 1
      }
    } else {
      out.write_char(c)
    }
    index = index + 1
  }
  out.to_string()
}

///|
/// Drop the spaces and tabs at the end of one line.
fn trim_line_end(line : StringView) -> String {
  let chars = line.to_owned().to_array()
  let mut end = chars.length()
  while end > 0 && (chars[end - 1] == ' ' || chars[end - 1] == '\t') {
    end = end - 1
  }
  String::from_array(chars[:end])
}

///|
/// Rebuild decoded text from its lines: line endings normalized, trailing spaces
/// dropped, blank lines at the start and the end removed. The line breaks and the
/// indentation inside the text are the sender's, so they survive.
///
/// `squeeze` also caps runs of blank lines at one, for text stripped out of
/// HTML, where the layout of the source says nothing about the visible result.
fn join_text_lines(text : String, squeeze : Bool) -> String {
  let out = StringBuilder()
  let mut breaks = 0
  let mut wrote = false
  for raw in normalize_newlines(text).split("\n") {
    let line = trim_line_end(raw)
    if is_blank(line) {
      if wrote && (!squeeze || breaks < 2) {
        breaks = breaks + 1
      }
      continue
    }
    let mut index = 0
    while index < breaks {
      out.write_char('\n')
      index = index + 1
    }
    out.write_string(line)
    breaks = 1
    wrote = true
  }
  out.to_string()
}

///|
/// Extract readable text from a body plus its already-parsed headers.
///
/// IMAP returns the top-level headers (`HEADER`) and the body (`TEXT`)
/// separately, and `TEXT` does not repeat the top-level `Content-Type`, so the
/// caller has to pass the header list in for multipart mail to be recognised.
///
/// The body keeps its line breaks, because rules post it to chat services where
/// a single line is hard to read.
pub fn message_body_text_with_headers(
  headers : Array[(String, String)],
  raw_body : Bytes,
) -> String {
  let text : MimeText = { plain: "", html: "", }
  walk_mime(headers, raw_body, 0, text)
  let plain = join_text_lines(text.plain, false)
  if !is_blank(plain) {
    plain
  } else {
    join_text_lines(text.html, true)
  }
}

///|
/// Extract the readable text of a standalone MIME entity.
pub fn message_body_text(raw_body : Bytes) -> String {
  let (headers, body) = split_header_body(raw_body)
  message_body_text_with_headers(headers, body)
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
