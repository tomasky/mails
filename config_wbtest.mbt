///|
/// Configuration parsing is deliberately strict, so these tests pin the
/// accepted TOML shape and the error messages users see when it is wrong.

///|
let sample_toml : String =
  #|[general]
  #|startup_sync = true
  #|idle_timeout = "5m"
  #|reconnect_delay = "15s"
  #|max_body_bytes = 4096
  #|env_file = "keys.env"
  #|key_env = "MAILS_KEY"
  #|
  #|[[rules]]
  #|name = "global"
  #|keywords = ["invoice"]
  #|fields = ["subject", "body"]
  #|command = "true"
  #|
  #|[accounts.work]
  #|host = "imap.example.com"
  #|username = "me@example.com"
  #|password = "enc:v1:abc"
  #|mailboxes = ["INBOX", "Work"]
  #|tls = false
  #|
  #|[[accounts.work.rules]]
  #|name = "account_rule"
  #|keywords = ["deploy"]
  #|fields = ["from"]
  #|match = "all"
  #|timeout = "2m"
  #|command = "notify-send hi"

///|
test "parses general defaults and durations" {
  let config = parse_config("/etc/mails/mails.toml", sample_toml)
  assert_eq(config.defaults.startup_sync, true)
  assert_eq(config.defaults.idle_timeout_ms, 5 * 60_000)
  assert_eq(config.defaults.reconnect_ms, 15_000)
  assert_eq(config.defaults.max_body_bytes, 4096)
  assert_eq(config.env_file, "/etc/mails/keys.env")
  assert_eq(config.key_env, "MAILS_KEY")
}

///|
test "parses accounts and their overrides" {
  let config = parse_config("/etc/mails/mails.toml", sample_toml)
  assert_eq(config.accounts.length(), 1)
  let account = config.accounts[0]
  assert_eq(account.name, "work")
  assert_eq(account.host, "imap.example.com")
  assert_eq(account.port, 993)
  assert_eq(account.use_tls, false)
  assert_eq(account.mailboxes, ["INBOX", "Work"])
  assert_eq(account.password, "enc:v1:abc")
}

///|
test "parses global and per-account rules" {
  let config = parse_config("/etc/mails/mails.toml", sample_toml)
  assert_eq(config.rules.length(), 1)
  assert_eq(config.rules[0].name, "global")
  let account = config.accounts[0]
  assert_eq(account.rules.length(), 1)
  let account_rule = account.rules[0]
  assert_eq(account_rule.name, "account_rule")
  assert_eq(account_rule.fields.length(), 1)
  assert_eq(account_rule.fields[0].as_string(), "from")
  assert_eq(account_rule.require_all, true)
  assert_eq(account_rule.timeout_ms, 2 * 60_000)
  assert_eq(account_rule.shell_command, "notify-send hi")
}

///|
fn config_error(source : String) -> String {
  let result : String? = (() => {
    ignore(parse_config("/x.toml", source))
    None
  })() catch {
    err => Some(error_message(err))
  }
  match result {
    Some(text) => text
    None => ""
  }
}

///|
test "rejects a config without accounts" {
  let message = config_error("[general]\nstartup_sync = true\n")
  assert_true(message.contains("declares no"))
}

///|
test "rejects a missing host" {
  let message = config_error("[accounts.a]\nusername = \"u\"\n")
  assert_true(message.contains("needs a 'host'"))
}

///|
test "accepts an empty password for the encrypt flow" {
  let config = parse_config(
    "/x.toml", "[accounts.a]\nhost = \"h\"\nusername = \"u\"\npassword = \"\"\n",
  )
  assert_eq(config.accounts[0].password, "")
}

///|
test "update_account_password replaces only the matching table" {
  let source = "# keep me\n[accounts.one]\nhost = \"h\"\npassword = \"old\"\n\n" +
    "[accounts.two]\npassword = \"other\"\n"
  let updated = update_account_password(source, "one", "enc:v1:new")
  assert_true(updated.contains("# keep me"))
  assert_true(
    updated.contains("[accounts.one]\nhost = \"h\"\npassword = \"enc:v1:new\""),
  )
  assert_true(updated.contains("[accounts.two]\npassword = \"other\""))
}

///|
test "update_account_password inserts a missing password line" {
  let source = "[accounts.one]\nhost = \"h\"\n\n[general]\nstartup_sync = false\n"
  let updated = update_account_password(source, "one", "enc:v1:new")
  assert_true(
    updated.contains(
      "[accounts.one]\nhost = \"h\"\npassword = \"enc:v1:new\"\n",
    ),
  )
}

///|
test "update_account_password rejects an unknown account" {
  let result : String? = (() => {
    ignore(update_account_password("[accounts.one]\n", "two", "x"))
    None
  })() catch {
    err => Some(error_message(err))
  }
  assert_true(result.unwrap().contains("no [accounts.two]"))
}

///|
test "duration parser understands units and rejects garbage" {
  assert_eq(parse_duration_ms("500ms"), Some(500))
  assert_eq(parse_duration_ms("30s"), Some(30_000))
  assert_eq(parse_duration_ms("10m"), Some(600_000))
  assert_eq(parse_duration_ms("2h"), Some(7_200_000))
  assert_eq(parse_duration_ms("1d"), Some(86_400_000))
  assert_eq(parse_duration_ms("nonsense"), None)
  assert_eq(parse_duration_ms("10"), None)
}

///|
test "rejects an invalid rule regex at load time" {
  let source = "[accounts.a]\nhost = \"h\"\nusername = \"u\"\n\n" +
    "[[rules]]\nname = \"bad\"\nkeywords = [\"[\"]\nregex = true\ncommand = \"true\"\n"
  let message = config_error(source)
  assert_true(message.contains("invalid regular expression"))
}
