///|
/// SMTP, just enough to deliver one message.
///
/// `mails` was an IMAP watcher first, so the SMTP side is deliberately small:
/// no queue, no retries beyond one connection, no pipelining. It speaks
/// `EHLO`, upgrades with `STARTTLS` when the server offers it, authenticates
/// with `PLAIN`, `LOGIN` or `XOAUTH2`, and hands the message over with
/// `MAIL FROM` / `RCPT TO` / `DATA`.
///
/// Two connection styles are supported:
///
/// - implicit TLS, usually port 465 (`smtp_tls = true`)
/// - plaintext greeting then `STARTTLS`, usually port 587 (`smtp_starttls = true`)
///
/// Plaintext without TLS is allowed only when the account sets
/// `smtp_tls_verify = false` *and* the port is loopback, because sending a
/// password over a clear channel is worse than refusing to send.
pub enum SmtpStream {
  SmtpPlain(@socket.Tcp)
  SmtpSecure(@tls.Tls)
}

///|
async fn smtp_read_line(stream : SmtpStream) -> String? {
  match stream {
    SmtpPlain(tcp) => tcp.read_until("\r\n")
    SmtpSecure(tls) => tls.read_until("\r\n")
  }
}

///|
async fn smtp_write(stream : SmtpStream, text : String) -> Unit {
  smtp_write_bytes(stream, string_to_bytes(text))
}

///|
async fn smtp_write_bytes(stream : SmtpStream, data : Bytes) -> Unit {
  match stream {
    SmtpPlain(tcp) => tcp.write(data)
    SmtpSecure(tls) => tls.write(data)
  }
}

///|
fn smtp_close(stream : SmtpStream) -> Unit {
  match stream {
    SmtpPlain(tcp) => tcp.close()
    SmtpSecure(tls) => tls.close()
  }
}

///|
/// A server reply: the numeric status plus every line of text.
pub struct SmtpReply {
  code : Int32
  lines : Array[String]
}

///|
fn smtp_reply_text(reply : SmtpReply) -> String {
  reply.lines.join(" ")
}

///|
/// Read one (possibly multi-line) reply.
///
/// The last line of a multi-line reply has a space instead of the `-` after the
/// code: `250-first`, `250-second`, `250 last`.
async fn smtp_read_reply(stream : SmtpStream) -> SmtpReply {
  let lines : Array[String] = []
  let mut code = 0
  let mut reading = true
  while reading {
    let line = match smtp_read_line(stream) {
      Some(text) => text
      None => raise MailsError("the SMTP server closed the connection")
    }
    if line.length() < 3 {
      raise MailsError("malformed SMTP reply: " + line)
    }
    code = @string.parse_int(line[0:3].to_owned()) catch {
      _ => raise MailsError("malformed SMTP reply: " + line)
    }
    let rest = if line.length() > 4 { line[4:].to_owned() } else { "" }
    lines.push(rest)
    reading = line.length() > 3 && line[3] == '-'
  }
  { code, lines, }
}

///|
fn smtp_require(
  reply : SmtpReply,
  expected : Array[Int32],
  step : String,
) -> Unit raise {
  for code in expected {
    if reply.code == code {
      return
    }
  }
  raise MailsError(
    step + " failed: " + reply.code.to_string() + " " + smtp_reply_text(reply),
  )
}

///|
/// The capabilities a server advertised, upper-cased keyword only.

///|
/// The capability keywords, split into single tokens.
///
/// Servers answer `250-STARTTLS` and `250-AUTH PLAIN LOGIN`, so a line can
/// carry several keywords; keeping only the first would lose the AUTH
/// mechanisms, which is exactly what decides how we log in.
fn smtp_capabilities(reply : SmtpReply) -> Array[String] {
  let out : Array[String] = []
  for line in reply.lines {
    for token in trim(line).split(" ") {
      let name = trim(token).to_upper()
      if name != "" {
        out.push(name)
      }
    }
  }
  out
}

///|
pub fn smtp_has_capability(capabilities : Array[String], name : String) -> Bool {
  let wanted = name.to_upper()
  for capability in capabilities {
    if capability == wanted {
      return true
    }
  }
  false
}

///|
/// `AUTH PLAIN` payload: NUL-separated `authorization-id`, `authentication-id`
/// and password, base64 encoded.
pub fn smtp_plain_response(username : String, password : String) -> String {
  base64_encode(string_to_bytes("\u{0}" + username + "\u{0}" + password))
}

///|
pub struct SmtpClient {
  stream : SmtpStream
  host : String
  capabilities : Array[String]
}

///|
/// Open a connection and say hello.
///
/// `implicit_tls` wraps the socket straight away (port 465); otherwise the
/// greeting arrives in the clear and `starttls` decides whether to upgrade
/// before authenticating.
pub async fn SmtpClient::connect(
  host : String,
  port : Int32,
  implicit_tls : Bool,
  starttls : Bool,
  verify_tls : Bool,
) -> SmtpClient {
  let tcp = @socket.Tcp::connect_to_host(host, port~) catch {
    err =>
      raise MailsError(
        "cannot connect to the SMTP server " + host + ": " + err.to_string(),
      )
  }
  tcp.enable_keepalive() catch {
    _ => ()
  }
  let trust = if verify_tls { @tls.SystemRoot } else { @tls.NoVerification }
  let stream : SmtpStream = if implicit_tls {
    SmtpSecure(@tls.Tls::client(tcp, host~, trust~))
  } else {
    SmtpPlain(tcp)
  }
  let greeting = smtp_read_reply(stream)
  smtp_require(greeting, [220], "SMTP greeting")
  let mut client : SmtpClient = { stream, host, capabilities: [], }
  client = client.hello()
  if !implicit_tls && starttls {
    if !smtp_has_capability(client.capabilities, "STARTTLS") {
      smtp_close(client.stream)
      raise MailsError(
        "the SMTP server does not offer STARTTLS; use port 465 with " +
        "smtp_tls = true, or set smtp_starttls = false to send in the clear",
      )
    }
    smtp_write(client.stream, "STARTTLS\r\n")
    let reply = smtp_read_reply(client.stream)
    smtp_require(reply, [220], "STARTTLS")
    let upgraded = match client.stream {
      SmtpPlain(tcp) => SmtpSecure(@tls.Tls::client(tcp, host~, trust~))
      SmtpSecure(tls) => SmtpSecure(tls)
    }
    client = { ..client, stream: upgraded, }
    // The capability list from before the upgrade does not describe the
    // encrypted session, so ask again.
    client = client.hello()
  }
  client
}

///|
async fn SmtpClient::hello(client : SmtpClient) -> SmtpClient {
  // A server that does not know EHLO answers `500`; RFC 5321 then wants HELO.
  smtp_write(client.stream, "EHLO mails\r\n")
  let reply = smtp_read_reply(client.stream)
  if reply.code == 250 {
    { ..client, capabilities: smtp_capabilities(reply), }
  } else {
    smtp_write(client.stream, "HELO mails\r\n")
    let helo = smtp_read_reply(client.stream)
    smtp_require(helo, [250], "HELO")
    { ..client, capabilities: [], }
  }
}

///|
/// Which AUTH mechanism to use, given what the server offers.
///
/// `XOAUTH2` wins when an access token is available, `PLAIN` beats `LOGIN`
/// because it is one round trip. Servers that advertise no `AUTH` line are
/// treated as "plain password accepted on this port", which is what several
/// relays behind a VPN do.
pub enum SmtpAuth {
  SmtpAuthNone
  SmtpAuthPlain(String, String)
  SmtpAuthLogin(String, String)
  SmtpAuthXoauth2(String, String)
}

///|
pub fn choose_smtp_auth(
  capabilities : Array[String],
  username : String,
  password : String,
  access_token : String?,
) -> SmtpAuth {
  let advertise = smtp_has_capability(capabilities, "AUTH")
  match access_token {
    Some(token) =>
      if !advertise || smtp_has_capability(capabilities, "XOAUTH2") {
        return SmtpAuthXoauth2(username, token)
      }
    None => ()
  }
  if password == "" {
    return SmtpAuthNone
  }
  if !advertise {
    return SmtpAuthPlain(username, password)
  }
  if smtp_has_capability(capabilities, "PLAIN") {
    SmtpAuthPlain(username, password)
  } else if smtp_has_capability(capabilities, "LOGIN") {
    SmtpAuthLogin(username, password)
  } else {
    // No supported mechanism advertised; try PLAIN and let the server decide.
    SmtpAuthPlain(username, password)
  }
}

///|
/// Authenticate. Errors never contain the password or the token.
pub async fn SmtpClient::authenticate(
  client : SmtpClient,
  auth : SmtpAuth,
) -> Unit {
  match auth {
    SmtpAuthNone => ()
    SmtpAuthPlain(username, password) => {
      smtp_write(
        client.stream,
        "AUTH PLAIN " + smtp_plain_response(username, password) + "\r\n",
      )
      let reply = smtp_read_reply(client.stream)
      if reply.code != 235 {
        raise MailsError(
          "the SMTP server rejected AUTH PLAIN: " +
          reply.code.to_string() +
          " " +
          smtp_reply_text(reply),
        )
      }
    }
    SmtpAuthLogin(username, password) => {
      smtp_write(client.stream, "AUTH LOGIN\r\n")
      let challenge = smtp_read_reply(client.stream)
      smtp_require(challenge, [334], "AUTH LOGIN")
      smtp_write(
        client.stream,
        base64_encode(string_to_bytes(username)) + "\r\n",
      )
      let password_challenge = smtp_read_reply(client.stream)
      smtp_require(password_challenge, [334], "AUTH LOGIN")
      smtp_write(
        client.stream,
        base64_encode(string_to_bytes(password)) + "\r\n",
      )
      let reply = smtp_read_reply(client.stream)
      if reply.code != 235 {
        raise MailsError(
          "the SMTP server rejected AUTH LOGIN: " +
          reply.code.to_string() +
          " " +
          smtp_reply_text(reply),
        )
      }
    }
    SmtpAuthXoauth2(username, token) => {
      // The initial response carries the token, so nothing but a redacted
      // error may be logged from here.
      smtp_write(
        client.stream,
        "AUTH XOAUTH2 " + xoauth2_initial_response(username, token) + "\r\n",
      )
      let mut reply = smtp_read_reply(client.stream)
      if reply.code == 334 {
        // Error challenge; an empty line lets the server send its final reply.
        smtp_write(client.stream, "\r\n")
        reply = smtp_read_reply(client.stream)
      }
      if reply.code != 235 {
        raise MailsError(
          "the SMTP server rejected AUTH XOAUTH2 <redacted>: " +
          reply.code.to_string() +
          " " +
          smtp_reply_text(reply),
        )
      }
    }
  }
}

///|
/// Who the message is from and to, as SMTP sees it: `Bcc` recipients are here
/// but not in the message headers.
pub struct SmtpEnvelope {
  from : String
  to : Array[String]
}

///|
/// Check an address and return its bare form.
///
/// `Name <addr>` is accepted and reduced to `addr`, because that is what
/// `RCPT TO` needs. A CR or LF would let a caller inject extra `RCPT` lines,
/// so it is rejected outright.
pub fn validate_address(address : String) -> String raise {
  // Checked before trimming: a line break anywhere, even at the end, is a sign
  // that the value was built by concatenation and should not be trusted.
  if address.contains("\r") || address.contains("\n") {
    raise MailsError("email address must not contain a line break")
  }
  let trimmed = trim(address)
  if trimmed == "" {
    raise MailsError("empty email address")
  }
  let bare = if trimmed.contains("<") {
    let open = match trimmed.find("<") {
      Some(index) => index
      None => 0
    }
    let rest = trimmed[open + 1:].to_owned()
    let close = match rest.find(">") {
      Some(index) => index
      None => raise MailsError("'" + trimmed + "' is missing its closing '>'")
    }
    if trim(rest[close + 1:]) != "" {
      raise MailsError("'" + trimmed + "' has text after the closing '>'")
    }
    trim(rest[:close])
  } else {
    if trimmed.contains(">") {
      raise MailsError("'" + trimmed + "' is not an email address")
    }
    trimmed
  }
  if bare == "" {
    raise MailsError("empty email address")
  }
  let mut at = 0
  for c in bare {
    if c == '@' {
      at = at + 1
    }
    if c == ' ' || c == '\t' {
      raise MailsError("'" + bare + "' is not an email address")
    }
  }
  if at != 1 || bare.has_prefix("@") || bare.has_suffix("@") {
    raise MailsError("'" + trimmed + "' is not an email address")
  }
  bare
}

///|
/// Split a `--to a@b,c@d` value, or a string of the same shape.
pub fn split_addresses(text : String) -> Array[String] raise {
  let out : Array[String] = []
  for comma in text.split(",") {
    for part in comma.split(";") {
      let trimmed = trim(part)
      if trimmed == "" {
        // A trailing separator is a typo, not an empty recipient.
        continue
      }
      out.push(validate_address(trimmed))
    }
  }
  if out.length() == 0 {
    raise MailsError("no recipient address given")
  }
  out
}

///|
/// Deliver `message` to every recipient in `envelope`.
///
/// The message must already be a complete RFC 5322 document (headers, blank
/// line, body); this function fixes line endings, dot-stuffs and adds the
/// terminator.
pub async fn SmtpClient::send(
  client : SmtpClient,
  envelope : SmtpEnvelope,
  message : Bytes,
) -> Unit {
  let from = validate_address(envelope.from)
  if envelope.to.length() == 0 {
    raise MailsError("message has no recipients")
  }
  smtp_write(client.stream, "MAIL FROM:<" + from + ">\r\n")
  smtp_require(smtp_read_reply(client.stream), [250], "MAIL FROM")
  let accepted : Array[String] = []
  let refused : Array[String] = []
  for recipient in envelope.to {
    let address = validate_address(recipient)
    smtp_write(client.stream, "RCPT TO:<" + address + ">\r\n")
    let reply = smtp_read_reply(client.stream)
    if reply.code == 250 || reply.code == 251 {
      accepted.push(recipient)
    } else {
      refused.push(
        address +
        " (" +
        reply.code.to_string() +
        " " +
        smtp_reply_text(reply) +
        ")",
      )
    }
  }
  if accepted.length() == 0 {
    // Give up cleanly so the server does not keep a half-open transaction.
    smtp_write(client.stream, "RSET\r\n")
    ignore(smtp_read_reply(client.stream))
    raise MailsError("every recipient was refused: " + refused.join("; "))
  }
  smtp_write(client.stream, "DATA\r\n")
  smtp_require(smtp_read_reply(client.stream), [354], "DATA")
  smtp_write_bytes(client.stream, dot_stuff_bytes(message))
  smtp_write(client.stream, "\r\n.\r\n")
  smtp_require(smtp_read_reply(client.stream), [250], "sending the message")
  if refused.length() > 0 {
    raise MailsError(
      "the message was delivered, but these recipients were refused: " +
      refused.join("; "),
    )
  }
}

///|
/// Say goodbye. Errors are ignored: the message is already delivered by the
/// time this runs.
pub async fn SmtpClient::close(client : SmtpClient) -> Unit {
  smtp_write(client.stream, "QUIT\r\n") catch {
    _ => ()
  }
  ignore(smtp_read_reply(client.stream) catch { _ => { code: 0, lines: [], } })
  smtp_close(client.stream)
}

///|
/// Dot-stuffing plus CRLF normalisation, the two things SMTP does to a body.
///
/// A line that starts with `.` would end the message early, and a bare LF is not
/// allowed on the wire, so both are fixed here rather than at every call site.
pub fn dot_stuff_bytes(message : Bytes) -> Bytes {
  let normalized = normalize_newlines(bytes_to_string_lossy(message))
  // Drop one trailing newline: the caller writes `\r\n.\r\n` after this, which
  // already ends the last line.
  let text = if normalized.has_suffix("\n") {
    normalized[:normalized.length() - 1].to_owned()
  } else {
    normalized
  }
  let lines : Array[String] = []
  for raw in text.split("\n") {
    let line = if raw.has_prefix(".") {
      "." + raw.to_owned()
    } else {
      raw.to_owned()
    }
    lines.push(line)
  }
  string_to_bytes(lines.join("\r\n"))
}
