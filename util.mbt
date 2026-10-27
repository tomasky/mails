///|
/// Errors raised by `mails` and reported to the user without a stack trace.
pub suberror MailsError {
  MailsError(String)
}

///|
pub fn mails_error(msg : String) -> MailsError {
  MailsError(msg)
}

///|
pub fn trim(s : StringView) -> String {
  s.trim().to_owned()
}

///|
pub fn is_blank(s : String) -> Bool {
  trim(s) == ""
}

///|
pub fn base64_encode(data : Bytes) -> String {
  @base64.encode(data)
}

///|
pub fn base64_decode(text : String) -> Bytes raise MailsError {
  @base64.decode(text) catch {
    _ => raise MailsError("invalid base64 data")
  }
}

///|
pub fn bytes_concat(parts : ArrayView[Bytes]) -> Bytes {
  let mut len = 0
  for part in parts {
    len = len + part.length()
  }
  let out = Array::make(len, b'\x00')
  let mut offset = 0
  for part in parts {
    for i in 0..<part.length() {
      out[offset + i] = part[i]
    }
    offset = offset + part.length()
  }
  Bytes::from_array(out[:])
}

///|
pub fn bytes_to_string_lossy(data : Bytes) -> String {
  @utf8.decode_lossy(data)
}

///|
pub fn string_to_bytes(text : String) -> Bytes {
  @utf8.encode(text)
}

///|
/// Parse a human duration such as `30s`, `5m`, `1h` or `250ms` into ms.
pub fn parse_duration_ms(text : String) -> Int32? {
  let t = trim(text).to_lower()
  if t == "" {
    return None
  }
  let mut digits = ""
  let mut unit = ""
  for c in t {
    if c >= '0' && c <= '9' {
      if unit != "" {
        return None
      }
      digits = digits + c.to_string()
    } else if c == ' ' || c == '_' {
      continue
    } else {
      unit = unit + c.to_string()
    }
  }
  if digits == "" {
    return None
  }
  let number = @string.parse_int(digits) catch { _ => return None }
  let factor = match unit {
    "s" | "sec" | "secs" => 1000
    "ms" | "msec" | "msecs" => 1
    "m" | "min" | "mins" => 60_000
    "h" | "hr" | "hrs" => 3_600_000
    "d" | "day" | "days" => 86_400_000
    _ => return None
  }
  Some(number * factor)
}

///|
/// Format milliseconds for log messages.
pub fn format_duration(ms : Int32) -> String {
  if ms >= 86_400_000 && ms % 86_400_000 == 0 {
    "\{ms / 86_400_000}d"
  } else if ms >= 3_600_000 && ms % 3_600_000 == 0 {
    "\{ms / 3_600_000}h"
  } else if ms >= 60_000 && ms % 60_000 == 0 {
    "\{ms / 60_000}m"
  } else if ms >= 1000 && ms % 1000 == 0 {
    "\{ms / 1000}s"
  } else {
    "\{ms}ms"
  }
}

///|
/// Escape a string for use inside an IMAP quoted string (RFC 3501).
pub fn imap_quote(text : String) -> String {
  let out = StringBuilder()
  out.write_char('"')
  for c in text {
    if c == '\\' || c == '"' {
      out.write_char('\\')
    }
    out.write_char(c)
  }
  out.write_char('"')
  out.to_string()
}

///|
/// Collapse runs of whitespace into single spaces and trim the result.
pub fn collapse_whitespace(text : String) -> String {
  let out = StringBuilder()
  let mut has_out = false
  let mut pending_space = false
  for c in text {
    if c == ' ' || c == '\t' || c == '\r' || c == '\n' {
      if has_out {
        pending_space = true
      }
    } else {
      if pending_space {
        out.write_char(' ')
        pending_space = false
      }
      out.write_char(c)
      has_out = true
    }
  }
  out.to_string()
}

///|
/// Truncate to at most `max_chars` characters, appending an ellipsis.
pub fn truncate_chars(text : String, max_chars : Int32) -> String {
  if text.char_length() <= max_chars {
    return text
  }
  let out = StringBuilder()
  let mut count = 0
  for c in text {
    if count >= max_chars {
      break
    }
    out.write_char(c)
    count = count + 1
  }
  out.write_char('…')
  out.to_string()
}

///|
pub enum LogLevel {
  Warn
  Info
  Debug
}

///|
pub let log_level : Ref[LogLevel] = Ref(Info)

///|
pub fn set_log_level(level : LogLevel) -> Unit {
  log_level.val = level
}

///|
pub fn log_error(msg : String) -> Unit {
  eprintln("mails: error: " + msg)
}

///|
pub fn log_warn(msg : String) -> Unit {
  eprintln("mails: warning: " + msg)
}

///|
pub fn log_info(msg : String) -> Unit {
  match log_level.val {
    Warn => ()
    _ => eprintln("mails: " + msg)
  }
}

///|
pub fn log_debug(msg : String) -> Unit {
  match log_level.val {
    Debug => eprintln("mails: debug: " + msg)
    _ => ()
  }
}

///|
/// Quote a string for safe interpolation into a POSIX shell command.
pub fn shell_quote(text : String) -> String {
  let out = StringBuilder()
  out.write_char('\'')
  for c in text {
    if c == '\'' {
      out.write_string("'\\''")
    } else {
      out.write_char(c)
    }
  }
  out.write_char('\'')
  out.to_string()
}

///|
/// The user-facing message of an error, without the `MailsError(...)` wrapper.
pub fn error_message(err : Error) -> String {
  match err {
    MailsError(text) => text
    ImapProtocolError(text) => text
    IdleUnsupported => "the server does not support IDLE"
    _ => err.to_string()
  }
}
