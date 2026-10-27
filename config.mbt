///| Configuration model and TOML loader.
///
/// `mails` reads exactly one configuration file, `mails.toml`, from the
/// directory holding the `mails` executable (override with `--config`). The
/// `.env` file holding the encryption key lives in that same directory unless
/// `general.env_file` says otherwise.

///|
pub let config_file_name : String = "mails.toml"

///|
pub enum MatchField {
  Subject
  Body
  From
  To
}

///|
pub fn MatchField::as_string(self : MatchField) -> String {
  match self {
    Subject => "subject"
    Body => "body"
    From => "from"
    To => "to"
  }
}

///|
pub struct Rule {
  name : String
  accounts : Array[String]
  mailboxes : Array[String]
  fields : Array[MatchField]
  keywords : Array[String]
  require_all : Bool
  ignore_case : Bool
  regex : Bool
  shell_command : String
  argv : Array[String]
  timeout_ms : Int32
  workdir : String
  body_chars : Int32
}

///|
pub struct Defaults {
  startup_sync : Bool
  idle_timeout_ms : Int32
  reconnect_ms : Int32
  max_body_bytes : Int32
  command_timeout_ms : Int32
  body_chars : Int32
}

///|
pub struct Account {
  name : String
  host : String
  port : Int32
  username : String
  password : String
  use_tls : Bool
  tls_verify : Bool
  mailboxes : Array[String]
  rules : Array[Rule]
  startup_sync : Bool
  idle_timeout_ms : Int32
  reconnect_ms : Int32
  max_body_bytes : Int32
}

///|
pub struct Config {
  path : String
  dir : String
  env_file : String
  key_env : String
  defaults : Defaults
  rules : Array[Rule]
  accounts : Array[Account]
}

///|
pub fn default_defaults() -> Defaults {
  {
    startup_sync: false,
    idle_timeout_ms: 29 * 60_000,
    reconnect_ms: 30_000,
    max_body_bytes: 256 * 1024,
    command_timeout_ms: 30_000,
    body_chars: 4_000,
  }
}

///|
/// Directory containing the running executable.
pub async fn executable_dir() -> String raise MailsError {
  let argv = @env.args()
  if argv.length() == 0 {
    raise MailsError("cannot determine the location of the mails binary")
  }
  let exe = argv[0]
  let resolved = if exe.contains("/") {
    @fs.realpath(exe) catch {
      _ =>
        raise MailsError("cannot resolve the path of the mails binary: " + exe)
    }
  } else {
    let path = match @env.get_env_var("PATH") {
      Some(value) => value
      None => "/usr/account_rule/bin:/usr/bin:/bin"
    }
    let mut found = ""
    for dir in path.split(":") {
      let candidate = dir.to_owned() + "/" + exe
      let exists = @fs.exists(candidate) catch { _ => false }
      if exists {
        found = @fs.realpath(candidate) catch { _ => candidate }
        break
      }
    }
    if found == "" {
      raise MailsError("cannot find the mails binary on PATH")
    }
    found
  }
  match resolved.rev_find("/") {
    Some(index) => resolved[0:index].to_owned()
    None => "."
  }
}

///|
/// The config path used when `--config` is not passed.
pub async fn default_config_path() -> String raise MailsError {
  match @env.get_env_var("MAILS_CONFIG") {
    Some(path) if !is_blank(path) => trim(path)
    _ => executable_dir() + "/" + config_file_name
  }
}

///|
fn value_as_string(value : @toml.TomlValue) -> String? {
  match value {
    @toml.TomlString(text) => Some(text)
    _ => None
  }
}

///|
fn value_as_bool(value : @toml.TomlValue) -> Bool? {
  match value {
    @toml.TomlBoolean(flag) => Some(flag)
    _ => None
  }
}

///|
fn value_as_int(value : @toml.TomlValue) -> Int32? {
  match value {
    @toml.TomlInteger(number) => Some(number.to_int())
    _ => None
  }
}

///|
fn value_as_table(value : @toml.TomlValue) -> Map[String, @toml.TomlValue]? {
  match value {
    @toml.TomlTable(table) => Some(table)
    _ => None
  }
}

///|
fn value_as_array(value : @toml.TomlValue) -> Array[@toml.TomlValue]? {
  match value {
    @toml.TomlArray(items) => Some(items)
    _ => None
  }
}

///|
fn read_string(
  table : Map[String, @toml.TomlValue],
  key : String,
  what : String,
) -> String? raise MailsError {
  match table.get(key) {
    None => None
    Some(value) =>
      match value_as_string(value) {
        Some(text) => Some(text)
        None => raise MailsError(what + " must be a string")
      }
  }
}

///|
fn read_bool(
  table : Map[String, @toml.TomlValue],
  key : String,
  what : String,
) -> Bool? raise MailsError {
  match table.get(key) {
    None => None
    Some(value) =>
      match value_as_bool(value) {
        Some(flag) => Some(flag)
        None => raise MailsError(what + " must be true or false")
      }
  }
}

///|
fn read_int(
  table : Map[String, @toml.TomlValue],
  key : String,
  what : String,
) -> Int32? raise MailsError {
  match table.get(key) {
    None => None
    Some(value) =>
      match value_as_int(value) {
        Some(number) => Some(number)
        None => raise MailsError(what + " must be an integer")
      }
  }
}

///|
fn read_string_array(
  table : Map[String, @toml.TomlValue],
  key : String,
  what : String,
) -> Array[String]? raise MailsError {
  match table.get(key) {
    None => None
    Some(value) =>
      match value_as_array(value) {
        Some(items) => {
          let out : Array[String] = []
          for item in items {
            match value_as_string(item) {
              Some(text) => out.push(text)
              None => raise MailsError(what + " must be an array of strings")
            }
          }
          Some(out)
        }
        None => raise MailsError(what + " must be an array of strings")
      }
  }
}

///|
fn read_duration(
  table : Map[String, @toml.TomlValue],
  key : String,
  what : String,
) -> Int32? raise MailsError {
  match read_string(table, key, what) {
    None => None
    Some(text) =>
      match parse_duration_ms(text) {
        Some(ms) => {
          if ms < 0 {
            raise MailsError(what + " must not be negative")
          }
          Some(ms)
        }
        None =>
          raise MailsError(what + " is not a duration (try \"30s\", \"5m\")")
      }
  }
}

///|
fn table_field(
  table : Map[String, @toml.TomlValue],
  key : String,
  what : String,
) -> Map[String, @toml.TomlValue]? raise MailsError {
  match table.get(key) {
    None => None
    Some(value) =>
      match value_as_table(value) {
        Some(inner) => Some(inner)
        None => raise MailsError(what + " must be a table")
      }
  }
}

///|
fn array_of_tables(
  table : Map[String, @toml.TomlValue],
  key : String,
  what : String,
) -> Array[Map[String, @toml.TomlValue]]? raise MailsError {
  match table.get(key) {
    None => None
    Some(value) =>
      match value_as_array(value) {
        Some(items) => {
          let out : Array[Map[String, @toml.TomlValue]] = []
          for item in items {
            match value_as_table(item) {
              Some(inner) => out.push(inner)
              None => raise MailsError(what + " must be an array of tables")
            }
          }
          Some(out)
        }
        None => raise MailsError(what + " must be an array of tables")
      }
  }
}

///|
pub fn parse_match_field(text : String) -> MatchField? {
  match trim(text).to_lower() {
    "subject" | "title" => Some(Subject)
    "body" | "content" | "text" => Some(Body)
    "from" | "sender" => Some(From)
    "to" | "recipient" => Some(To)
    _ => None
  }
}

///|
fn parse_rule(
  table : Map[String, @toml.TomlValue],
  defaults : Defaults,
  index : Int32,
) -> Rule raise MailsError {
  let name = match read_string(table, "name", "rule name") {
    Some(text) if !is_blank(text) => trim(text)
    _ => "rule-" + (index + 1).to_string()
  }
  let what = "rule '" + name + "': "
  let keywords = match read_string_array(table, "keywords", what + "keywords") {
    Some(items) => {
      if items.length() == 0 {
        raise MailsError(what + "needs at least one keyword")
      }
      items
    }
    None =>
      match read_string(table, "keyword", what + "keyword") {
        Some(text) if !is_blank(text) => [trim(text)]
        _ => raise MailsError(what + "needs a 'keywords' array")
      }
  }
  let fields = match read_string_array(table, "fields", what + "fields") {
    Some(items) => {
      let out : Array[MatchField] = []
      for item in items {
        match parse_match_field(item) {
          Some(field) => out.push(field)
          None =>
            raise MailsError(
              what +
              "unknown field '" +
              item +
              "' (use subject, body, from or to)",
            )
        }
      }
      if out.length() == 0 {
        raise MailsError(what + "needs at least one field")
      }
      out
    }
    None => [Subject, Body]
  }
  let require_all = match read_string(table, "match", what + "match") {
    Some(text) =>
      match trim(text).to_lower() {
        "all" | "every" | "and" => true
        "any" | "or" => false
        _ => raise MailsError(what + "'match' must be 'any' or 'all'")
      }
    None =>
      match read_bool(table, "require_all", what + "require_all") {
        Some(flag) => flag
        None => false
      }
  }
  let ignore_case = match
    read_bool(table, "case_sensitive", what + "case_sensitive") {
    Some(flag) => !flag
    None => true
  }
  let regex = match read_bool(table, "regex", what + "regex") {
    Some(flag) => flag
    None => false
  }
  if regex {
    for keyword in keywords {
      let pattern = if ignore_case { "(?i:" + keyword + ")" } else { keyword }
      let compiled = @string.Regex::Regex(pattern) catch {
        _ =>
          raise MailsError(
            what + "invalid regular expression '" + keyword + "'",
          )
      }
      ignore(compiled)
    }
  }
  let shell_command = match read_string(table, "command", what + "command") {
    Some(text) => trim(text)
    None => ""
  }
  let argv = match read_string_array(table, "exec", what + "exec") {
    Some(items) => items
    None => []
  }
  if shell_command == "" && argv.length() == 0 {
    raise MailsError(what + "needs a 'command' string or an 'exec' array")
  }
  let timeout_ms = match read_duration(table, "timeout", what + "timeout") {
    Some(ms) => ms
    None => defaults.command_timeout_ms
  }
  let workdir = match read_string(table, "workdir", what + "workdir") {
    Some(text) => text
    None => ""
  }
  let body_chars = match read_int(table, "body_chars", what + "body_chars") {
    Some(number) => {
      if number < 0 {
        raise MailsError(what + "body_chars must not be negative")
      }
      number
    }
    None => defaults.body_chars
  }
  let accounts = match read_string_array(table, "accounts", what + "accounts") {
    Some(items) => items
    None => []
  }
  let mailboxes = match
    read_string_array(table, "mailboxes", what + "mailboxes") {
    Some(items) => items
    None => []
  }
  {
    name,
    accounts,
    mailboxes,
    fields,
    keywords,
    require_all,
    ignore_case,
    regex,
    shell_command,
    argv,
    timeout_ms,
    workdir,
    body_chars,
  }
}

///|
fn parse_rules(
  table : Map[String, @toml.TomlValue],
  defaults : Defaults,
  what : String,
) -> Array[Rule] raise MailsError {
  match array_of_tables(table, "rules", what) {
    Some(items) => {
      let out : Array[Rule] = []
      let mut index = 0
      for item in items {
        out.push(parse_rule(item, defaults, index))
        index = index + 1
      }
      out
    }
    None => []
  }
}

///|
fn parse_defaults(
  general : Map[String, @toml.TomlValue]?,
) -> Defaults raise MailsError {
  let base = default_defaults()
  match general {
    None => base
    Some(table) => {
      let startup_sync = match
        read_bool(table, "startup_sync", "general.startup_sync") {
        Some(flag) => flag
        None => base.startup_sync
      }
      let idle_timeout_ms = match
        read_duration(table, "idle_timeout", "general.idle_timeout") {
        Some(ms) => ms
        None => base.idle_timeout_ms
      }
      let reconnect_ms = match
        read_duration(table, "reconnect_delay", "general.reconnect_delay") {
        Some(ms) => ms
        None => base.reconnect_ms
      }
      let max_body_bytes = match
        read_int(table, "max_body_bytes", "general.max_body_bytes") {
        Some(number) => {
          if number < 0 {
            raise MailsError("general.max_body_bytes must not be negative")
          }
          number
        }
        None => base.max_body_bytes
      }
      let command_timeout_ms = match
        read_duration(table, "command_timeout", "general.command_timeout") {
        Some(ms) => ms
        None => base.command_timeout_ms
      }
      let body_chars = match
        read_int(table, "body_chars", "general.body_chars") {
        Some(number) => {
          if number < 0 {
            raise MailsError("general.body_chars must not be negative")
          }
          number
        }
        None => base.body_chars
      }
      {
        startup_sync,
        idle_timeout_ms,
        reconnect_ms,
        max_body_bytes,
        command_timeout_ms,
        body_chars,
      }
    }
  }
}

///|
fn parse_account(
  name : String,
  table : Map[String, @toml.TomlValue],
  defaults : Defaults,
) -> Account raise MailsError {
  let what = "account '" + name + "': "
  let host = match read_string(table, "host", what + "host") {
    Some(text) if !is_blank(text) => trim(text)
    _ => raise MailsError(what + "needs a 'host'")
  }
  let username = match read_string(table, "username", what + "username") {
    Some(text) if !is_blank(text) => trim(text)
    _ => raise MailsError(what + "needs a 'username'")
  }
  // An empty password is allowed at parse time so `mails encrypt --write`
  // can fill it in; connecting without one is rejected with a clear message.
  let password = match read_string(table, "password", what + "password") {
    Some(text) => trim(text)
    None => ""
  }
  let port = match read_int(table, "port", what + "port") {
    Some(number) => {
      if number <= 0 || number > 65535 {
        raise MailsError(what + "port must be between 1 and 65535")
      }
      number
    }
    None => 993
  }
  let use_tls = match read_bool(table, "tls", what + "tls") {
    Some(flag) => flag
    None => true
  }
  let tls_verify = match read_bool(table, "tls_verify", what + "tls_verify") {
    Some(flag) => flag
    None => true
  }
  let mailboxes = match
    read_string_array(table, "mailboxes", what + "mailboxes") {
    Some(items) => {
      if items.length() == 0 {
        raise MailsError(what + "needs at least one mailbox")
      }
      items
    }
    None => ["INBOX"]
  }
  let startup_sync = match
    read_bool(table, "startup_sync", what + "startup_sync") {
    Some(flag) => flag
    None => defaults.startup_sync
  }
  let idle_timeout_ms = match
    read_duration(table, "idle_timeout", what + "idle_timeout") {
    Some(ms) => {
      if ms < 1000 {
        raise MailsError(what + "idle_timeout must be at least 1s")
      }
      ms
    }
    None => defaults.idle_timeout_ms
  }
  let reconnect_ms = match
    read_duration(table, "reconnect_delay", what + "reconnect_delay") {
    Some(ms) => ms
    None => defaults.reconnect_ms
  }
  let max_body_bytes = match
    read_int(table, "max_body_bytes", what + "max_body_bytes") {
    Some(number) => {
      if number < 0 {
        raise MailsError(what + "max_body_bytes must not be negative")
      }
      number
    }
    None => defaults.max_body_bytes
  }
  let rules = parse_rules(table, defaults, what + "rules")
  {
    name,
    host,
    port,
    username,
    password,
    use_tls,
    tls_verify,
    mailboxes,
    rules,
    startup_sync,
    idle_timeout_ms,
    reconnect_ms,
    max_body_bytes,
  }
}

///|
/// Parse a TOML document, resolving nothing (paths are handled by the caller).
pub fn parse_config(path : String, source : String) -> Config raise MailsError {
  let root = @toml.parse(source) catch {
    _ => raise MailsError("cannot parse " + path + " as TOML")
  }
  let table = match value_as_table(root) {
    Some(table) => table
    None => raise MailsError(path + " must contain a TOML table")
  }
  let general = table_field(table, "general", "[general]")
  let defaults = parse_defaults(general)
  let env_file_name = match general {
    Some(general_table) =>
      match read_string(general_table, "env_file", "general.env_file") {
        Some(text) if !is_blank(text) => trim(text)
        _ => ".env"
      }
    None => ".env"
  }
  let key_env = match general {
    Some(general_table) =>
      match read_string(general_table, "key_env", "general.key_env") {
        Some(text) if !is_blank(text) => trim(text)
        _ => default_key_env
      }
    None => default_key_env
  }
  let dir = match path.rev_find("/") {
    Some(index) => path[0:index].to_owned()
    None => "."
  }
  let env_file = if env_file_name.has_prefix("/") {
    env_file_name
  } else {
    dir + "/" + env_file_name
  }
  let rules = parse_rules(table, defaults, "global rules")
  let accounts : Array[Account] = []
  match table_field(table, "accounts", "[accounts]") {
    Some(accounts_table) =>
      for pair in accounts_table {
        let (name, value) = pair
        let account_table = match value_as_table(value) {
          Some(inner) => inner
          None => raise MailsError("account '" + name + "' must be a table")
        }
        accounts.push(parse_account(name, account_table, defaults))
      }
    None => ()
  }
  if accounts.length() == 0 {
    raise MailsError(path + " declares no [accounts.<name>] tables")
  }
  { path, dir, env_file, key_env, defaults, rules, accounts, }
}

///|
/// Load and parse the configuration file.
pub async fn load_config(path : String) -> Config raise MailsError {
  let text = @fs.read_file(path) catch {
    _ => raise MailsError("cannot read the config file " + path)
  }
  let source = text.text() catch {
    _ => raise MailsError("the config file " + path + " is not valid UTF-8")
  }
  parse_config(path, source)
}

///|
/// Accounts selected by `--account`, or all of them.
pub fn selected_accounts(
  config : Config,
  name : String?,
) -> Array[Account] raise MailsError {
  match name {
    None => config.accounts
    Some(wanted) => {
      let out : Array[Account] = []
      for account in config.accounts {
        if account.name == wanted {
          out.push(account)
        }
      }
      if out.length() == 0 {
        raise MailsError("no account named '" + wanted + "' in " + config.path)
      }
      out
    }
  }
}

///|
/// Replace the `password` entry of one `[accounts.<name>]` table in the TOML
/// source, leaving every other line untouched. Used by `mails encrypt --write`.
pub fn update_account_password(
  source : String,
  account : String,
  value : String,
) -> String raise MailsError {
  let lines : Array[String] = []
  for line in source.split("\n") {
    lines.push(line.to_owned())
  }
  let header = "[accounts." + account + "]"
  let mut in_table = false
  let mut table_seen = false
  let mut replaced = false
  let mut insert_at = -1
  let mut index = 0
  while index < lines.length() {
    let stripped = trim(lines[index])
    if stripped.has_prefix("[") {
      if in_table && !replaced && insert_at < 0 {
        insert_at = index
      }
      in_table = stripped == header
      if in_table {
        table_seen = true
        insert_at = index + 1
      }
    } else if in_table && stripped != "" {
      insert_at = index + 1
      if !replaced && stripped.has_prefix("password") {
        match stripped.find("=") {
          Some(_) => {
            let leading = lines[index][0:lines[index]
            .find("password")
            .unwrap_or(0)].to_owned()
            lines[index] = leading + "password = \"" + value + "\""
            replaced = true
          }
          None => ()
        }
      }
    }
    index = index + 1
  }
  if !table_seen {
    raise MailsError("no [accounts." + account + "] table in the config file")
  }
  if !replaced {
    if insert_at < 0 {
      insert_at = lines.length()
    }
    lines.insert(insert_at, "password = \"" + value + "\"")
  }
  let out = StringBuilder()
  let mut first = true
  for line in lines {
    if !first {
      out.write_char('\n')
    }
    first = false
    out.write_string(line)
  }
  out.to_string()
}

///|
/// A commented starter configuration written by `mails init`.
pub fn sample_config() -> String {
  let lines : Array[String] = [
    "# mails configuration. Keep this file next to the mails binary.", "", "[general]",
    "# Process mail that already exists when a mailbox is first watched.", "startup_sync = false",
    "# Leave IDLE and re-enter it this often (servers drop idle clients).", "idle_timeout = \"29m\"",
    "# Wait this long before reconnecting after a failure.", "reconnect_delay = \"30s\"",
    "# Only fetch this many bytes of each message body.", "max_body_bytes = 262144",
    "# File holding the encryption key; relative to this config file.", "env_file = \".env\"",
    "key_env = \"MAILS_KEY\"", "", "# Rules are matched against every new message. A rule runs its command",
    "# once per matching message. Placeholders such as {{subject}} and", "# {{from_q}} are expanded, and the same values are exported as MAILS_*",
    "# environment variables.", "", "[[rules]]", "name = \"urgent\"", "keywords = [\"urgent\", \"invoice\"]",
    "fields = [\"subject\", \"body\"]", "match = \"any\"          # \"any\" or \"all\"",
    "case_sensitive = false", "regex = false", "# command = 'notify-send \"Mail from {{from}}\" \"{{subject}}\"'",
    "command = 'printf \"%s\\n\" \"new mail: {{subject}}\" >> /tmp/mails.log'", "",
    "[accounts.example]", "host = \"imap.example.com\"", "port = 993", "username = \"you@example.com\"",
    "", "# Run: mails encrypt --account example --write", "password = \"\"", "",
    "mailboxes = [\"INBOX\"]", "# startup_sync = true        # override [general] for this account",
  ]
  let out = StringBuilder()
  for line in lines {
    out.write_string(line)
    out.write_char('\n')
  }
  out.to_string()
}
