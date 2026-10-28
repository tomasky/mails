///| OAuth 2.0 for headless servers.
///
/// Microsoft and Google no longer accept a username and password over IMAP, so
/// those accounts need OAuth. On a server there is no browser to redirect
/// back to, which is exactly the case the device authorization grant
/// (RFC 8628) covers: we ask the provider for a short code, print a URL and
/// the code, and poll until the user approves it from their phone or laptop.
///
/// The refresh token is the long-lived secret; the access token is derived
/// from it on demand and kept in memory. Tokens never reach the logs.

///|
pub enum AuthKind {
  PasswordLogin
  OAuth2Login
}

///|
/// Resolved OAuth endpoints and settings for one account.
pub struct OAuthSettings {
  provider : String
  client_id : String
  tenant : String
  scope : String
  device_endpoint : String
  token_endpoint : String
  token_file : String
}

///|
/// The RFC 8628 device authorization response.
pub struct DeviceAuthorization {
  device_code : String
  user_code : String
  verification_uri : String
  verification_uri_complete : String
  interval_ms : Int32
  expires_in_s : Int32
  message : String
}

///|
/// An access token and the refresh token that replaces it.
pub struct TokenSet {
  access_token : String
  refresh_token : String
  expires_at_ms : Int64
}

///|
/// Access tokens live for about an hour; treat them as stale a little early so
/// a request never starts with a token that expires mid-handshake.
let token_slack_ms : Int64 = 60_000L

///|
/// Microsoft documents `outlook.office.com` for the IMAP scope; Google uses the
/// single `mail.google.com` scope. Both are overridable from the config.
pub fn oauth_provider_defaults(
  provider : String,
  tenant : String,
) -> (String, String, String) raise MailsError {
  match provider {
    "microsoft" => {
      let tenant = if is_blank(tenant) { "common" } else { trim(tenant) }
      (
        "https://login.microsoftonline.com/" +
        tenant +
        "/oauth2/v2.0/devicecode",
        "https://login.microsoftonline.com/" + tenant + "/oauth2/v2.0/token",
        "offline_access https://outlook.office.com/IMAP.AccessAsUser.All",
      )
    }
    "google" =>
      (
        "https://oauth2.googleapis.com/device/code", "https://oauth2.googleapis.com/token",
        "https://mail.google.com/",
      )
    "custom" =>
      raise MailsError(
        "the 'custom' OAuth provider needs oauth_device_endpoint, " +
        "oauth_token_endpoint and oauth_scope",
      )
    other => raise MailsError("unknown oauth_provider '" + other + "'")
  }
}

///|
/// Percent-encode one form value (RFC 3986 unreserved characters stay as-is).
fn form_escape(text : String) -> String {
  let out = StringBuilder()
  for byte in string_to_bytes(text) {
    let value = byte.to_int()
    let plain = (value >= 0x41 && value <= 0x5A) ||
      (value >= 0x61 && value <= 0x7A) ||
      (value >= 0x30 && value <= 0x39) ||
      value == 0x2D ||
      value == 0x2E ||
      value == 0x5F ||
      value == 0x7E ||
      value == 0x20
    if plain {
      if value == 0x20 {
        out.write_char('+')
      } else {
        out.write_char(value.unsafe_to_char())
      }
    } else {
      out.write_char('%')
      out.write_string(hex_byte(value))
    }
  }
  out.to_string()
}

///|
fn hex_byte(value : Int32) -> String {
  let digits : Array[Char] = [
    '0', '1', '2', '3', '4', '5', '6', '7', '8', '9', 'A', 'B', 'C', 'D', 'E', 'F',
  ]
  let out = StringBuilder()
  out.write_char(digits[(value >> 4) & 0xF])
  out.write_char(digits[value & 0xF])
  out.to_string()
}

///|
fn form_encode(pairs : Array[(String, String)]) -> String {
  let out = StringBuilder()
  let mut first = true
  for pair in pairs {
    let (key, value) = pair
    if !first {
      out.write_char('&')
    }
    first = false
    out.write_string(form_escape(key))
    out.write_char('=')
    out.write_string(form_escape(value))
  }
  out.to_string()
}

///|
/// POST an `application/x-www-form-urlencoded` body and return the decoded
/// JSON. A non-200 response is turned into an error that carries the
/// provider's own description, which is far more useful than a bare status.
async fn post_form(
  url : String,
  pairs : Array[(String, String)],
) -> Json raise MailsError {
  let headers : Map[@http.CaseInsensitiveString, String] = Map([])
  headers.set(
    @http.CaseInsensitiveString("Content-Type"),
    "application/x-www-form-urlencoded",
  )
  headers.set(@http.CaseInsensitiveString("Accept"), "application/json")
  let body = form_encode(pairs)
  // A fixed content length keeps proxies happy; without it async sends the
  // body chunked.
  headers.set(
    @http.CaseInsensitiveString("Content-Length"),
    string_to_bytes(body).length().to_string(),
  )
  // Without a timeout a stuck token endpoint would hang startup and `mails
  // check` forever.
  let outcome = @async.with_timeout_opt(30_000, () => {
    @http.post(url, body, headers~)
  }) catch {
    err => raise MailsError("cannot reach " + url + ": " + err.to_string())
  }
  let (response, data) = match outcome {
    Some(pair) => pair
    None => raise MailsError("timed out after 30s waiting for " + url)
  }
  let text = data.text() catch {
    _ => raise MailsError("cannot read the response from " + url)
  }
  let json = @json.parse(text) catch {
    _ =>
      raise MailsError(
        "unexpected response from " +
        url +
        " (HTTP " +
        response.code.to_string() +
        "): " +
        truncate_chars(text, 200),
      )
  }
  if response.code != 200 {
    let detail = match json_field_string(json, "error_description") {
      Some(text) => text
      None =>
        match json_field_string(json, "error") {
          Some(code) => code
          None => truncate_chars(text, 200)
        }
    }
    raise MailsError(
      "OAuth endpoint " +
      url +
      " returned HTTP " +
      response.code.to_string() +
      ": " +
      detail,
    )
  }
  json
}

///|
/// Like `post_form`, but keeps the error as a message so the polling loop can
/// inspect it (the device grant reports "authorization_pending" as an error).
async fn post_form_result(
  url : String,
  pairs : Array[(String, String)],
) -> Result[Json, String] noraise {
  let json = post_form(url, pairs) catch {
    err => return Err(error_message(err))
  }
  Ok(json)
}

///|
fn json_field(json : Json, name : String) -> Json? {
  match json {
    Object(fields) => fields.get(name)
    _ => None
  }
}

///|
fn json_field_string(json : Json, name : String) -> String? {
  match json_field(json, name) {
    Some(String(text)) => Some(text)
    _ => None
  }
}

///|
fn json_field_int(json : Json, name : String) -> Int32? {
  match json_field(json, name) {
    Some(Number(value, ..)) => Some(value.to_int())
    _ => None
  }
}

///|
/// Ask the provider for a device code and the URL the user has to visit.
pub async fn request_device_code(
  settings : OAuthSettings,
) -> DeviceAuthorization raise MailsError {
  if is_blank(settings.client_id) {
    raise MailsError(
      "this account needs oauth_client_id (create an app registration first)",
    )
  }
  let json = post_form(settings.device_endpoint, [
    ("client_id", settings.client_id),
    ("scope", settings.scope),
  ])
  let device_code = match json_field_string(json, "device_code") {
    Some(value) if !is_blank(value) => value
    _ => raise MailsError("the device code response has no device_code")
  }
  let user_code = match json_field_string(json, "user_code") {
    Some(value) if !is_blank(value) => value
    _ => raise MailsError("the device code response has no user_code")
  }
  let verification_uri = match json_field_string(json, "verification_uri") {
    Some(value) if !is_blank(value) => value
    None =>
      match json_field_string(json, "verification_url") {
        Some(value) if !is_blank(value) => value
        _ =>
          raise MailsError("the device code response has no verification_uri")
      }
    Some(_) =>
      raise MailsError("the device code response has no verification_uri")
  }
  let verification_uri_complete = match
    json_field_string(json, "verification_uri_complete") {
    Some(value) => value
    None => ""
  }
  let expires_in_s = match json_field_int(json, "expires_in") {
    Some(value) if value > 0 => value
    _ => 900
  }
  let interval_s = match json_field_int(json, "interval") {
    Some(value) if value > 0 => value
    _ => 5
  }
  let message = match json_field_string(json, "message") {
    Some(value) => value
    None => ""
  }
  {
    device_code,
    user_code,
    verification_uri,
    verification_uri_complete,
    interval_ms: interval_s * 1000,
    expires_in_s,
    message,
  }
}

///|
fn token_from_json(json : Json) -> TokenSet raise MailsError {
  let access_token = match json_field_string(json, "access_token") {
    Some(value) if !is_blank(value) => value
    _ => raise MailsError("the token response has no access_token")
  }
  let refresh_token = match json_field_string(json, "refresh_token") {
    Some(value) => value
    None => ""
  }
  let expires_in = match json_field_int(json, "expires_in") {
    Some(value) if value > 0 => value
    _ => 3600
  }
  {
    access_token,
    refresh_token,
    expires_at_ms: @async.now() + expires_in.to_int64() * 1000L,
  }
}

///|
/// Poll the token endpoint until the user approves the device code.
///
/// `on_pending` is called after every poll so the caller can report progress
/// without knowing the polling rules.
pub async fn poll_device_token(
  settings : OAuthSettings,
  authorization : DeviceAuthorization,
  on_pending : () -> Unit,
) -> TokenSet raise MailsError {
  let deadline = @async.now() + authorization.expires_in_s.to_int64() * 1000L
  let mut interval_ms = if authorization.interval_ms > 0 {
    authorization.interval_ms
  } else {
    5_000
  }
  while @async.now() < deadline {
    @async.sleep(interval_ms)
    let outcome = post_form_result(settings.token_endpoint, [
      ("grant_type", "urn:ietf:params:oauth:grant-type:device_code"),
      ("device_code", authorization.device_code),
      ("client_id", settings.client_id),
    ])
    match outcome {
      Ok(json) => return token_from_json(json)
      Err(message) => {
        if message.contains("authorization_pending") {
          on_pending()
          continue
        }
        if message.contains("slow_down") {
          interval_ms = interval_ms + 5_000
          on_pending()
          continue
        }
        if message.contains("expired_token") {
          raise MailsError(
            "the device code expired before it was approved; run `mails login` again",
          )
        }
        if message.contains("authorization_declined") ||
          message.contains("access_denied") {
          raise MailsError("the sign-in request was declined")
        }
        raise MailsError(message)
      }
    }
  }
  raise MailsError("timed out waiting for the device code to be approved")
}

///|
/// Exchange a refresh token for a new access token.
pub async fn refresh_access_token(
  settings : OAuthSettings,
  refresh_token : String,
) -> TokenSet raise MailsError {
  let json = post_form(settings.token_endpoint, [
    ("grant_type", "refresh_token"),
    ("refresh_token", refresh_token),
    ("client_id", settings.client_id),
    ("scope", settings.scope),
  ])
  let refreshed = token_from_json(json)
  if is_blank(refreshed.refresh_token) {
    // Providers that do not rotate the refresh token omit it; keep the old one.
    { ..refreshed, refresh_token, }
  } else {
    refreshed
  }
}

///|
/// The token file holds the refresh token (never the access token), either
/// sealed with the configured key or, when no key is configured, in clear text
/// with mode 0600.
fn default_token_file(config_dir : String, account_name : String) -> String {
  config_dir + "/." + account_name + ".oauth"
}

///|
pub fn token_path(account : Account, config_dir : String) -> String {
  if is_blank(account.oauth_token_file) {
    default_token_file(config_dir, account.name)
  } else if account.oauth_token_file.has_prefix("/") {
    account.oauth_token_file
  } else {
    config_dir + "/" + account.oauth_token_file
  }
}

///|
fn json_escape(text : String) -> String {
  let out = StringBuilder()
  for c in text {
    match c {
      '"' => out.write_string("\\\"")
      '\\' => out.write_string("\\\\")
      '\n' => out.write_string("\\n")
      '\r' => out.write_string("\\r")
      '\t' => out.write_string("\\t")
      _ => out.write_char(c)
    }
  }
  out.to_string()
}

///|
/// Persist the refresh token for `account`, sealed when a key is available.
pub async fn save_refresh_token(
  path : String,
  account : Account,
  refresh_token : String,
  key : String,
) -> Unit raise MailsError {
  let stored = if is_blank(key) {
    refresh_token
  } else {
    seal_secret(key, refresh_token) catch {
      err =>
        raise MailsError("cannot seal the refresh token: " + error_message(err))
    }
  }
  let document = "{\"version\":1" +
    ",\"provider\":\"" +
    json_escape(account.oauth_provider) +
    "\"" +
    ",\"client_id\":\"" +
    json_escape(account.oauth_client_id) +
    "\"" +
    ",\"refresh_token\":\"" +
    json_escape(stored) +
    "\"}\n"
  @fs.write_file(path, string_to_bytes(document), permission=0o600) catch {
    err => raise MailsError("cannot write " + path + ": " + error_message(err))
  }
  @fs.chmod(path, 0o600) catch {
    _ => ()
  }
}

///|
/// Read the refresh token previously stored by `mails login`.
pub async fn load_refresh_token(
  path : String,
  key : String,
) -> String? raise MailsError {
  let exists = @fs.exists(path) catch { _ => false }
  if !exists {
    return None
  }
  let text = @fs.read_file(path).text() catch {
    err => raise MailsError("cannot read " + path + ": " + error_message(err))
  }
  let json = @json.parse(text) catch {
    _ => raise MailsError(path + " is not a mails token file")
  }
  match json_field_string(json, "refresh_token") {
    Some(value) if !is_blank(value) => {
      let token = resolve_secret(key, value) catch {
        err =>
          raise MailsError(
            "cannot decrypt the refresh token in " +
            path +
            ": " +
            error_message(err),
          )
      }
      Some(token)
    }
    _ => None
  }
}

///|
/// Cache of live access tokens, keyed by account name. The watch loop opens one
/// connection per mailbox, and every one of them needs the same token; without
/// this each reconnect would perform its own refresh round-trip.
let access_token_cache : Map[String, TokenSet] = Map([])

///|
pub fn forget_access_token(account_name : String) -> Unit {
  access_token_cache.remove(account_name)
}

///|
/// Return a usable access token, refreshing it when it is missing or stale.
/// The refresh token is re-saved when the provider rotates it.
pub async fn access_token_for(
  account : Account,
  config_dir : String,
  key : String,
) -> String raise MailsError {
  let settings = oauth_settings_for(account, config_dir)
  let now = @async.now()
  match access_token_cache.get(account.name) {
    Some(cached) =>
      if cached.expires_at_ms - token_slack_ms > now {
        return cached.access_token
      }
    None => ()
  }
  let path = token_path(account, config_dir)
  let refresh_token = match load_refresh_token(path, key) {
    Some(token) => token
    None =>
      raise MailsError(
        "account '" +
        account.name +
        "' has no stored OAuth token; run `mails login --account " +
        account.name +
        "`",
      )
  }
  // A refresh token can be revoked or expired; drop the cached access token so
  // the next attempt starts clean instead of retrying a dead credential.
  errdefer forget_access_token(account.name)
  let tokens = refresh_access_token(settings, refresh_token)
  if tokens.refresh_token != refresh_token {
    save_refresh_token(path, account, tokens.refresh_token, key) catch {
      _ => ()
    }
  }
  access_token_cache.set(account.name, tokens)
  tokens.access_token
}

///|
/// Build the OAuthSettings for an account, filling provider defaults.
pub fn oauth_settings_for(
  account : Account,
  config_dir : String,
) -> OAuthSettings raise MailsError {
  let provider = if is_blank(account.oauth_provider) {
    "microsoft"
  } else {
    trim(account.oauth_provider)
  }
  let (device_default, token_default, scope_default) = if provider == "custom" {
    ("", "", "")
  } else {
    oauth_provider_defaults(provider, account.oauth_tenant)
  }
  let device_endpoint = if is_blank(account.oauth_device_endpoint) {
    device_default
  } else {
    trim(account.oauth_device_endpoint)
  }
  let token_endpoint = if is_blank(account.oauth_token_endpoint) {
    token_default
  } else {
    trim(account.oauth_token_endpoint)
  }
  if is_blank(device_endpoint) {
    raise MailsError(
      "account '" +
      account.name +
      "' needs oauth_device_endpoint (provider '" +
      provider +
      "')",
    )
  }
  if is_blank(token_endpoint) {
    raise MailsError(
      "account '" +
      account.name +
      "' needs oauth_token_endpoint (provider '" +
      provider +
      "')",
    )
  }
  let scope = if is_blank(account.oauth_scope) {
    scope_default
  } else {
    trim(account.oauth_scope)
  }
  if is_blank(scope) {
    raise MailsError(
      "account '" +
      account.name +
      "' needs oauth_scope (provider '" +
      provider +
      "')",
    )
  }
  {
    provider,
    client_id: trim(account.oauth_client_id),
    tenant: trim(account.oauth_tenant),
    scope,
    device_endpoint,
    token_endpoint,
    token_file: token_path(account, config_dir),
  }
}

///|
/// Build the credential for an account: a resolved password, or a live OAuth2
/// access token refreshed on demand.
pub async fn credential_for(
  account : Account,
  config_dir : String,
  key : String,
) -> Credential raise MailsError {
  match account.auth {
    PasswordLogin => {
      if is_blank(account.password) {
        raise MailsError(
          "account '" +
          account.name +
          "' has no password; run `mails encrypt --account " +
          account.name +
          " --write`",
        )
      }
      Password(resolve_secret(key, account.password))
    }
    OAuth2Login => Bearer(access_token_for(account, config_dir, key))
  }
}
