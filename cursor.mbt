///| Persist the last handled UID per account/mailbox so a reconnect does not
/// rescan mail that was already processed.
///
/// The cursor used to live only in memory, and the `UIDNEXT` reported by the
/// server was trusted to recover it. Servers that answer `UIDNEXT 0` (and the
/// first run after an upgrade, where no cursor exists yet) therefore replayed
/// the whole mailbox and ran every matching rule command again. The cursor file
/// lives next to `mails.toml` as `.<account>.<mailbox>.cursor` with mode `0600`.

///|
/// Replace anything that is not safe in a file name, so a mailbox such as
/// `Sent Items/2026` still maps to a flat, usable path.
fn cursor_safe_name(name : String) -> String {
  let out = StringBuilder()
  for c in name {
    if (c >= 'a' && c <= 'z') ||
      (c >= 'A' && c <= 'Z') ||
      (c >= '0' && c <= '9') ||
      c == '-' ||
      c == '_' ||
      c == '.' {
      out.write_char(c)
    } else {
      out.write_char('_')
    }
  }
  out.to_string()
}

///|
/// FNV-1a over the account and mailbox name.
///
/// The readable part of the file name replaces every unusual character with
/// `_`, so `Sent Items` and `Sent/Items` would otherwise share one cursor file.
/// A short digest of the original names keeps them apart.
fn cursor_suffix(account_name : String, mailbox : String) -> String {
  let mut hash : UInt32 = 2166136261U
  for byte in string_to_bytes(account_name) {
    hash = (hash ^ byte.to_int().reinterpret_as_uint()) * 16777619U
  }
  // Separator, so ("ab", "c") and ("a", "bc") hash differently.
  hash = (hash ^ 31U) * 16777619U
  for byte in string_to_bytes(mailbox) {
    hash = (hash ^ byte.to_int().reinterpret_as_uint()) * 16777619U
  }
  let digits : Array[Char] = [
    '0', '1', '2', '3', '4', '5', '6', '7', '8', '9', 'a', 'b', 'c', 'd', 'e', 'f',
  ]
  let out = StringBuilder()
  let mut shift = 28
  while shift >= 0 {
    let nibble = ((hash >> shift) & 0xFU).reinterpret_as_int()
    out.write_char(digits[nibble])
    shift = shift - 4
  }
  out.to_string()
}

///|
/// Path of the cursor file for one account and mailbox.
pub fn cursor_path(
  config_dir : String,
  account_name : String,
  mailbox : String,
) -> String {
  config_dir +
  "/." +
  cursor_safe_name(account_name) +
  "." +
  cursor_safe_name(mailbox) +
  "." +
  cursor_suffix(account_name, mailbox) +
  ".cursor"
}

///|
/// Load the saved cursor as `(uid_validity, last_uid)`.
///
/// `(0, 0)` means "nothing usable on disk": still no cursor, an unreadable
/// file, or a file from a mailbox with a different UID space.
pub async fn load_cursor(
  config_dir : String,
  account_name : String,
  mailbox : String,
) -> (Int32, Int32) {
  let data = @fs.read_file(cursor_path(config_dir, account_name, mailbox)) catch {
    _ => return (0, 0)
  }
  let text = data.text() catch { _ => return (0, 0) }
  let mut uid_validity = 0
  let mut last_uid = 0
  for raw in text.split("\n") {
    let line = trim(raw)
    if line.has_prefix("uidvalidity=") {
      uid_validity = @string.parse_int(
        line["uidvalidity=".length():].to_owned(),
      ) catch {
        _ => return (0, 0)
      }
    } else if line.has_prefix("last_uid=") {
      last_uid = @string.parse_int(line["last_uid=".length():].to_owned()) catch {
        _ => return (0, 0)
      }
    }
  }
  if uid_validity < 0 || last_uid < 0 {
    return (0, 0)
  }
  (uid_validity, last_uid)
}

///|
/// Save the cursor atomically through a temp file plus rename, so a crash in
/// the middle never leaves a half-written cursor behind.
pub async fn save_cursor(
  config_dir : String,
  account_name : String,
  mailbox : String,
  uid_validity : Int32,
  last_uid : Int32,
) -> Unit {
  let path = cursor_path(config_dir, account_name, mailbox)
  let tmp = path + ".tmp"
  let body = "uidvalidity=" +
    uid_validity.to_string() +
    "\nlast_uid=" +
    last_uid.to_string() +
    "\n"
  @fs.write_file(tmp, body, create_mode=CreateOrTruncate, permission=0o600) catch {
    err => {
      log_warn("cannot save the cursor " + tmp + ": " + error_message(err))
      return
    }
  }
  @fs.chmod(tmp, 0o600) catch {
    _ => ()
  }
  @fs.rename(tmp, path, replace=true) catch {
    err =>
      log_warn("cannot save the cursor " + path + ": " + error_message(err))
  }
}
