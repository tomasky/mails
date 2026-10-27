///|
/// Secret storage.
///
/// Passwords are never stored in clear text in the configuration file. They
/// are ciphertext with AES-256-GCM under a key that lives in a `.env` file next to
/// the configuration. The ciphertext is a self-describing envelope:
///
/// ```text
/// enc:v1:<base64 salt>:<base64 nonce>:<base64 ciphertext+tag>
/// ```
///
/// The key itself may be a random 32-byte key (`b64:...` or `hex:...`) or a
/// passphrase (any other value), in which case PBKDF2-HMAC-SHA256 with the
/// envelope salt derives the AES key.
let envelope_prefix : String = "enc:v1:"

///|
let envelope_aad : Bytes = b"mails/v1"

///|
let pbkdf2_iterations : Int32 = 100_000

///|
pub let default_key_env : String = "MAILS_KEY"

///|
async fn random_bytes(count : Int32) -> Bytes raise MailsError {
  let file = @fs.open("/dev/urandom", mode=ReadOnly) catch {
    _ => raise MailsError("cannot open /dev/urandom")
  }
  defer file.close()
  file.read_exactly(count) catch {
    _ => raise MailsError("cannot read random bytes from /dev/urandom")
  }
}

///|
priv enum KeyMaterial {
  Raw(Bytes)
  Passphrase(Bytes)
}

///|
fn decode_hex(text : String) -> Bytes raise MailsError {
  @hex.decode(text) catch {
    _ => raise MailsError("the encryption key is not valid hexadecimal")
  }
}

///|
fn parse_key(spec : String) -> KeyMaterial raise MailsError {
  let text = trim(spec)
  if text == "" {
    raise MailsError("the encryption key is empty")
  }
  if text.has_prefix("b64:") {
    let key = base64_decode(text[4:].to_owned())
    if key.length() != 32 {
      raise MailsError("a b64: encryption key must decode to exactly 32 bytes")
    }
    Raw(key)
  } else if text.has_prefix("hex:") {
    let key = decode_hex(text[4:].to_owned())
    if key.length() != 32 {
      raise MailsError("a hex: encryption key must decode to exactly 32 bytes")
    }
    Raw(key)
  } else if text.has_prefix("raw:") {
    let key = string_to_bytes(text[4:].to_owned())
    if key.length() != 32 {
      raise MailsError("a raw: encryption key must be exactly 32 bytes")
    }
    Raw(key)
  } else if text.has_prefix("pass:") {
    Passphrase(string_to_bytes(text[5:].to_owned()))
  } else {
    Passphrase(string_to_bytes(text))
  }
}

///|
/// Generate a fresh 32-byte key in the `b64:` form used by `.env`.
pub async fn generate_key_spec() -> String raise MailsError {
  "b64:" + base64_encode(random_bytes(32))
}

///|
/// Derive the AES key for `spec`, using `salt` for passphrases.
fn derive_key(spec : String, salt : Bytes) -> Bytes raise MailsError {
  match parse_key(spec) {
    Raw(key) => key
    Passphrase(password) => {
      if password.length() == 0 {
        raise MailsError("the encryption passphrase is empty")
      }
      @lib.pbkdf2_hmac_sha256(password, salt, pbkdf2_iterations, 32)
    }
  }
}

///|
fn key_is_passphrase(spec : String) -> Bool raise MailsError {
  match parse_key(spec) {
    Raw(_) => false
    Passphrase(_) => true
  }
}

///|
/// Seal `plaintext` with the key from `key_spec`.
pub async fn seal_secret(
  key_spec : String,
  plaintext : String,
) -> String raise MailsError {
  let salt = random_bytes(16)
  let nonce = random_bytes(12)
  let key = derive_key(key_spec, salt)
  let encrypted = @lib.aes_gcm_encrypt(
    string_to_bytes(plaintext),
    key,
    nonce,
    envelope_aad,
  )
  let payload = bytes_concat([encrypted.ct, encrypted.tag])
  envelope_prefix +
  base64_encode(salt) +
  ":" +
  base64_encode(nonce) +
  ":" +
  base64_encode(payload)
}

///|
/// True when `text` looks like an `enc:v1:` envelope.
pub fn is_sealed(text : String) -> Bool {
  trim(text).has_prefix(envelope_prefix)
}

///|
/// Open an `enc:v1:` envelope with the key from `key_spec`.
pub fn open_secret(
  key_spec : String,
  envelope : String,
) -> String raise MailsError {
  let text = trim(envelope)
  if !text.has_prefix(envelope_prefix) {
    raise MailsError("not an encrypted value (expected the enc:v1: prefix)")
  }
  let rest = text[envelope_prefix.length():].to_owned()
  let parts : Array[String] = []
  for part in rest.split(":") {
    parts.push(part.to_owned())
  }
  if parts.length() != 3 {
    raise MailsError("malformed encrypted value")
  }
  let salt = base64_decode(parts[0])
  let nonce = base64_decode(parts[1])
  let payload = base64_decode(parts[2])
  if nonce.length() != 12 || payload.length() < 16 {
    raise MailsError("malformed encrypted value")
  }
  let ciphertext_len = payload.length() - 16
  let ciphertext = payload[:ciphertext_len].to_owned()
  let tag = payload[ciphertext_len:].to_owned()
  let key = derive_key(key_spec, salt)
  let plain = @lib.aes_gcm_decrypt(ciphertext, key, nonce, envelope_aad, tag)
  match plain {
    Ok(bytes) => bytes_to_string_lossy(bytes)
    Err(_) =>
      raise MailsError(
        "wrong encryption key, or the encrypted value is corrupt",
      )
  }
}

///|
/// Resolve a configured password: an `enc:` envelope is opened with `key`,
/// anything else is returned unchanged (for accounts that use another auth
/// mechanism or a password helper).
pub fn resolve_secret(
  key : String,
  configured : String,
) -> String raise MailsError {
  if is_sealed(configured) {
    open_secret(key, configured)
  } else {
    configured
  }
}

///|
/// Whether a configured secret needs a key to be resolved.
pub fn needs_key(configured : String) -> Bool {
  is_sealed(configured)
}

///|
/// Unused by the runtime, but kept honest by a test: whether `spec` is a
/// passphrase-derived key.
pub fn key_uses_passphrase(spec : String) -> Bool raise MailsError {
  key_is_passphrase(spec)
}
