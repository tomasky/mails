///| A small IMAP4rev1 client: enough of LOGIN, SELECT, UID FETCH and IDLE to
/// watch a mailbox. Every command gets its own tag and the reply is read up to
/// that tag, so unsolicited responses are kept in order.

///|
pub suberror IdleUnsupported

///|
pub suberror ImapProtocolError {
  ImapProtocolError(String)
}

///|
enum ImapStream {
  Plain(@socket.Tcp)
  Secure(@tls.Tls)
}

///|
async fn stream_read_line(stream : ImapStream) -> String? {
  match stream {
    Plain(tcp) => tcp.read_until("\r\n")
    Secure(tls) => tls.read_until("\r\n")
  }
}

///|
async fn stream_read_exactly(stream : ImapStream, len : Int32) -> Bytes {
  match stream {
    Plain(tcp) => tcp.read_exactly(len)
    Secure(tls) => tls.read_exactly(len)
  }
}

///|
async fn stream_write(stream : ImapStream, data : Bytes) -> Unit {
  match stream {
    Plain(tcp) => tcp.write(data)
    Secure(tls) => tls.write(data)
  }
}

///|
fn stream_close(stream : ImapStream) -> Unit {
  match stream {
    Plain(tcp) => tcp.close()
    Secure(tls) => tls.close()
  }
}

///|
pub struct LogicalLine {
  text : String
  prefixes : Array[String]
  literals : Array[Bytes]
}

///|
fn trailing_literal(line : String) -> (Int32, Int32)? {
  if !line.has_suffix("}") {
    return None
  }
  match line.find("{") {
    None => None
    Some(start) => {
      let digits = line[start + 1:line.length() - 1].to_owned()
      if digits == "" {
        return None
      }
      for c in digits {
        if c < '0' || c > '9' {
          return None
        }
      }
      let size = @string.parse_int(digits) catch { _ => -1 }
      if size < 0 {
        None
      } else {
        Some((start, size))
      }
    }
  }
}

///|
/// Read one protocol line, following `{N}` literals to their end.
async fn read_logical_line(stream : ImapStream) -> LogicalLine {
  let text = StringBuilder()
  // Text seen since the previous literal, so each literal can be attributed to
  // the section name that introduces it (`BODY[HEADER]`, `BODY[TEXT]`, ...).
  let segment = StringBuilder()
  let prefixes : Array[String] = []
  let literals : Array[Bytes] = []
  let mut first = true
  while true {
    let line = match stream_read_line(stream) {
      Some(line) => line
      None => raise ImapProtocolError("connection closed while reading a reply")
    }
    if !first {
      text.write_char(' ')
    }
    first = false
    match trailing_literal(line) {
      Some((start, size)) => {
        let head = line[0:start].to_owned()
        prefixes.push(segment.to_string() + head)
        segment.reset()
        text.write_string(head)
        text.write_char(' ')
        let data = stream_read_exactly(stream, size)
        literals.push(data)
      }
      None => {
        text.write_string(line)
        segment.write_string(line)
        break
      }
    }
  }
  { text: text.to_string(), prefixes, literals, }
}

///|
pub struct ImapReply {
  lines : Array[LogicalLine]
  status : String
  text : String
}

///|
fn reply_texts(reply : ImapReply) -> Array[String] {
  let out : Array[String] = []
  for line in reply.lines {
    out.push(line.text)
  }
  out
}

///|
pub struct MailboxStatus {
  exists : Int32
  uid_validity : Int32
  uid_next : Int32
}

///|
pub struct FetchedMessage {
  uid : String
  size : Int32
  header : Bytes
  body : Bytes
}

///|
pub struct ImapClient {
  stream : ImapStream
  host : String
  mut tag_counter : Int32
  mut capabilities : Array[String]
}

///|
/// Split `text` into whitespace-separated tokens, stripping parentheses.
fn tokens(text : String) -> Array[String] {
  let out : Array[String] = []
  for raw in text.split(" ") {
    let mut token = raw.to_owned()
    while token.has_prefix("(") {
      token = token[1:].to_owned()
    }
    while token.has_suffix(")") {
      token = token[0:token.length() - 1].to_owned()
    }
    if token != "" {
      out.push(token)
    }
  }
  out
}

///|
/// Return the token that follows `name`, if present.
fn token_after(text : String, name : String) -> String? {
  let parts = tokens(text)
  let mut index = 0
  while index + 1 < parts.length() {
    if parts[index].to_upper() == name.to_upper() {
      return Some(parts[index + 1])
    }
    index = index + 1
  }
  None
}

///|
fn token_int(text : String, name : String) -> Int32? {
  match token_after(text, name) {
    Some(raw) => {
      let value = @string.parse_int(raw) catch { _ => -1 }
      if value < 0 {
        None
      } else {
        Some(value)
      }
    }
    None => None
  }
}

///|
fn response_code(text : String, code : String) -> Int32? {
  // e.g. "* OK [UIDVALIDITY 1234] UIDs valid"
  let marker = "[" + code
  match text.find(marker) {
    None => None
    Some(index) => {
      let rest = text[index + marker.length():].to_owned()
      let digits = StringBuilder()
      for c in rest {
        if c >= '0' && c <= '9' {
          digits.write_char(c)
        } else if digits.to_string() != "" {
          break
        }
      }
      let raw = digits.to_string()
      if raw == "" {
        None
      } else {
        let value = @string.parse_int(raw) catch { _ => -1 }
        if value < 0 {
          None
        } else {
          Some(value)
        }
      }
    }
  }
}

///|
fn encode_modified_utf7(name : String) -> String {
  let out = StringBuilder()
  let pending : Array[Char] = []
  let flush = () => {
    if pending.length() == 0 {
      return
    }
    let bytes : Array[Byte] = []
    for c in pending {
      let code = c.to_int()
      bytes.push(((code >> 8) & 0xFF).to_byte())
      bytes.push((code & 0xFF).to_byte())
    }
    pending.clear()
    let encoded = @base64.encode(Bytes::from_array(bytes[:]))
    out.write_char('&')
    for c in encoded {
      if c == '/' {
        out.write_char(',')
      } else if c == '=' {
        break
      } else {
        out.write_char(c)
      }
    }
    out.write_char('-')
  }
  for c in name {
    if c == '&' {
      flush()
      out.write_string("&-")
    } else if c.to_int() >= 0x20 && c.to_int() < 0x7F {
      flush()
      out.write_char(c)
    } else {
      pending.push(c)
    }
  }
  flush()
  out.to_string()
}

///|

///|
/// Decode an IMAP modified-UTF-7 mailbox name.
pub fn decode_modified_utf7(name : String) -> String {
  let out = StringBuilder()
  let chars = name.to_array()
  let mut index = 0
  while index < chars.length() {
    let c = chars[index]
    if c != '&' {
      out.write_char(c)
      index = index + 1
      continue
    }
    // Find the closing '-' of this shift sequence.
    let mut end = index + 1
    while end < chars.length() && chars[end] != '-' {
      end = end + 1
    }
    if end >= chars.length() {
      out.write_char('&')
      index = index + 1
      continue
    }
    let encoded = name[index + 1:end].to_owned()
    if encoded == "" {
      out.write_char('&')
    } else {
      let normal = StringBuilder()
      for c in encoded {
        if c == ',' {
          normal.write_char('/')
        } else {
          normal.write_char(c)
        }
      }
      let mut padded = normal.to_string()
      while padded.length() % 4 != 0 {
        padded = padded + "="
      }
      let bytes = @base64.decode_lossy(padded)
      let mut offset = 0
      while offset + 1 < bytes.length() {
        let code = bytes[offset].to_int() * 256 + bytes[offset + 1].to_int()
        out.write_char(code.unsafe_to_char())
        offset = offset + 2
      }
    }
    index = end + 1
  }
  out.to_string()
}

///|
fn next_tag(client : ImapClient) -> String {
  client.tag_counter = client.tag_counter + 1
  "A" + client.tag_counter.to_string()
}

///|
/// Send one command and collect every untagged line up to its tagged reply.
async fn execute(client : ImapClient, command : String) -> ImapReply {
  let tag = next_tag(client)
  let line = tag + " " + command + "\r\n"
  stream_write(client.stream, string_to_bytes(line))
  let lines : Array[LogicalLine] = []
  let mut status = "BAD"
  let mut text = ""
  let mut done = false
  while !done {
    let reply = read_logical_line(client.stream)
    let head = reply.text
    if head.has_prefix(tag + " ") {
      let rest = head[tag.length() + 1:].to_owned()
      let parts = tokens(rest)
      if parts.length() > 0 {
        status = parts[0].to_upper()
        text = rest[parts[0].length():].to_owned()
      }
      done = true
    } else if head.has_prefix("+") {
      // Unexpected continuation; commands that expect one handle it themselves.
      lines.push(reply)
    } else {
      lines.push(reply)
    }
  }
  let reply : ImapReply = { lines, status, text, }
  if status == "NO" || status == "BAD" {
    raise ImapProtocolError(
      "server rejected '" + command + "': " + status + " " + text,
    )
  }
  reply
}

///|
/// Open a connection and log in.
pub async fn ImapClient::connect(
  host : String,
  port : Int32,
  use_tls : Bool,
  verify_tls : Bool,
  username : String,
  password : String,
) -> ImapClient {
  let tcp = @socket.Tcp::connect_to_host(host, port~) catch {
    err =>
      raise ImapProtocolError(
        "cannot connect to " + host + ": " + err.to_string(),
      )
  }
  tcp.enable_keepalive() catch {
    _ => ()
  }
  let stream : ImapStream = if use_tls {
    let trust = if verify_tls { @tls.SystemRoot } else { @tls.NoVerification }
    Secure(@tls.Tls::client(tcp, host~, trust~))
  } else {
    Plain(tcp)
  }
  let greeting = match stream_read_line(stream) {
    Some(line) => line
    None => {
      stream_close(stream)
      raise ImapProtocolError("no IMAP greeting from " + host)
    }
  }
  if !(greeting.to_upper().has_prefix("* OK") &&
    !greeting.to_upper().has_prefix("* BYE")) {
    stream_close(stream)
    raise ImapProtocolError("unexpected IMAP greeting: " + greeting)
  }
  let client : ImapClient = { stream, host, tag_counter: 0, capabilities: [], }
  // Greeting may advertise capabilities in a response code.
  match response_code(greeting.to_upper(), "CAPABILITY") {
    _ => ()
  }
  let login_cmd = "LOGIN " + imap_quote(username) + " " + imap_quote(password)
  ignore(execute(client, login_cmd))
  let caps = execute(client, "CAPABILITY")
  let capabilities : Array[String] = []
  for line in reply_texts(caps) {
    if line.to_upper().has_prefix("* CAPABILITY") {
      let rest = line[13:].to_owned()
      for token in tokens(rest) {
        capabilities.push(token.to_upper())
      }
    }
  }
  client.capabilities = capabilities
  client
}

///|
pub fn ImapClient::has_capability(client : ImapClient, name : String) -> Bool {
  let wanted = name.to_upper()
  for capability in client.capabilities {
    if capability == wanted {
      return true
    }
  }
  false
}

///|
pub async fn ImapClient::close(client : ImapClient) -> Unit {
  let line = next_tag(client) + " LOGOUT\r\n"
  stream_write(client.stream, string_to_bytes(line)) catch {
    _ => ()
  }
  stream_close(client.stream)
}

///|
/// SELECT a mailbox and read its UID bookkeeping.
pub async fn ImapClient::select_mailbox(
  client : ImapClient,
  mailbox : String,
) -> MailboxStatus {
  let reply = execute(
    client,
    "SELECT " + imap_quote(encode_modified_utf7(mailbox)),
  )
  let mut status : MailboxStatus = { exists: 0, uid_validity: 0, uid_next: 0, }
  for line in reply_texts(reply) {
    let upper = line.to_upper()
    if upper.has_prefix("* ") && upper.has_suffix(" EXISTS") {
      let parts = tokens(line)
      if parts.length() >= 2 {
        let value = @string.parse_int(parts[1]) catch { _ => -1 }
        if value >= 0 {
          status = { ..status, exists: value, }
        }
      }
    }
    match response_code(upper, "UIDVALIDITY") {
      Some(value) => status = { ..status, uid_validity: value, }
      None => ()
    }
    match response_code(upper, "UIDNEXT") {
      Some(value) => status = { ..status, uid_next: value, }
      None => ()
    }
  }
  status
}

///|
/// Fetch one message's header and (bounded) text body by UID.
pub async fn ImapClient::fetch_message(
  client : ImapClient,
  uid : String,
  max_body_bytes : Int32,
) -> FetchedMessage? {
  let command = "UID FETCH " +
    uid +
    " (UID RFC822.SIZE BODY.PEEK[HEADER] BODY.PEEK[TEXT]<0." +
    max_body_bytes.to_string() +
    ">)"
  let reply = execute(client, command)
  let mut header : Bytes? = None
  let mut body : Bytes? = None
  let mut size = 0
  let mut fetched_uid = uid
  for line in reply.lines {
    let upper = line.text.to_upper()
    if !upper.contains("FETCH") {
      continue
    }
    match token_after(line.text, "UID") {
      Some(value) => fetched_uid = value
      None => ()
    }
    match token_int(line.text, "RFC822.SIZE") {
      Some(value) => size = value
      None => ()
    }
    let mut index = 0
    while index < line.literals.length() {
      let prefix = if index < line.prefixes.length() {
        line.prefixes[index].to_upper()
      } else {
        ""
      }
      if prefix.contains("BODY[HEADER]") {
        header = Some(line.literals[index])
      } else if prefix.contains("BODY[TEXT]") {
        body = Some(line.literals[index])
      }
      index = index + 1
    }
  }
  match header {
    Some(header_bytes) => {
      let body_bytes = match body {
        Some(value) => value
        None => Bytes::new(0)
      }
      Some({ uid: fetched_uid, size, header: header_bytes, body: body_bytes, })
    }
    None => None
  }
}

///|
/// Try to enter IDLE and wait for a change. Falls back to an error the caller
/// can translate into polling.
pub async fn ImapClient::idle(client : ImapClient, timeout_ms : Int32) -> Bool {
  let tag = next_tag(client)
  stream_write(client.stream, string_to_bytes(tag + " IDLE\r\n"))
  // Wait for the continuation request.
  let mut started = false
  while !started {
    let line = read_logical_line(client.stream)
    let head = line.text
    if head.has_prefix(tag + " ") {
      raise IdleUnsupported
    }
    if head.has_prefix("+") {
      started = true
    }
  }
  let mut changed = false
  let mut keep_waiting = true
  while keep_waiting {
    let next = @async.with_timeout_opt(timeout_ms, () => {
      read_logical_line(client.stream)
    }) catch {
      err => {
        log_warn("IDLE read failed: " + err.to_string())
        None
      }
    }
    match next {
      None => keep_waiting = false
      Some(line) => {
        let upper = line.text.to_upper()
        if upper.contains(" EXISTS") || upper.contains(" RECENT") {
          changed = true
          keep_waiting = false
        }
      }
    }
  }
  stream_write(client.stream, string_to_bytes("DONE\r\n"))
  // Drain until the server confirms the end of IDLE.
  let mut finished = false
  while !finished {
    let line = @async.with_timeout_opt(30_000, () => {
      read_logical_line(client.stream)
    }) catch {
      _ => None
    }
    match line {
      None => finished = true
      Some(reply) => if reply.text.has_prefix(tag + " ") { finished = true }
    }
  }
  changed
}

///|
/// Ask the server for the current mailbox state without changing selection.
pub async fn ImapClient::check(
  client : ImapClient,
  mailbox : String,
) -> MailboxStatus {
  client.select_mailbox(mailbox)
}

///|
/// List the UIDs at or above `from_uid`, using `UID SEARCH UID n:*`.
pub async fn ImapClient::search_uids(
  client : ImapClient,
  from_uid : Int32,
) -> Array[String] {
  let reply = execute(client, "UID SEARCH UID " + from_uid.to_string() + ":*")
  let out : Array[String] = []
  for line in reply_texts(reply) {
    let upper = line.to_upper()
    if upper.has_prefix("* SEARCH") {
      let parts = tokens(line)
      let mut index = 2
      while index < parts.length() {
        out.push(parts[index])
        index = index + 1
      }
    }
  }
  out
}
