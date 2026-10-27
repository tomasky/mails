///| The `mails` command-line interface.

///|
let cli_version : String = "0.1.4"

///|
priv struct CliOptions {
  mut command : String
  mut config : String?
  mut account : String?
  mut write : Bool
  mut new_key : Bool
  mut once : Bool
  mut no_verify : Bool
  mut help : Bool
}

///|
fn default_options() -> CliOptions {
  {
    command: "",
    config: None,
    account: None,
    write: false,
    new_key: false,
    once: false,
    no_verify: false,
    help: false,
  }
}

///|
async fn print_line(text : String) -> Unit {
  @stdio.stdout.write(text + "\n")
}

///|
async fn print_error(text : String) -> Unit {
  @stdio.stderr.write("mails: " + text + "\n")
}

///|
fn cli_error(message : String) -> MailsError {
  MailsError(message)
}

///|
fn parse_args(argv : Array[String]) -> CliOptions raise {
  let opts = default_options()
  let mut index = 1
  while index < argv.length() {
    let arg = argv[index]
    if arg == "--config" || arg == "-c" {
      index = index + 1
      if index >= argv.length() {
        raise cli_error("--config needs a path")
      }
      opts.config = Some(argv[index])
    } else if arg == "--account" || arg == "-a" {
      index = index + 1
      if index >= argv.length() {
        raise cli_error("--account needs a name")
      }
      opts.account = Some(argv[index])
    } else if arg == "--write" {
      opts.write = true
    } else if arg == "--new-key" {
      opts.new_key = true
    } else if arg == "--once" {
      opts.once = true
    } else if arg == "--no-verify" {
      opts.no_verify = true
    } else if arg == "--help" || arg == "-h" {
      opts.help = true
    } else if arg == "--version" || arg == "-V" {
      opts.command = "version"
    } else if arg == "--verbose" || arg == "-v" {
      set_log_level(Debug)
    } else if arg == "--quiet" || arg == "-q" {
      set_log_level(Warn)
    } else if arg.has_prefix("-") && opts.command == "" {
      raise cli_error("unknown option " + arg)
    } else if opts.command == "" {
      opts.command = arg
    } else {
      raise cli_error("unexpected argument '" + arg + "'")
    }
    index = index + 1
  }
  opts
}

///|
async fn print_help() -> Unit {
  let lines : Array[String] = [
    "mails " +
    cli_version +
    " - watch IMAP mailboxes and run commands on keyword matches",
    "",
    "usage: mails <command> [options]",
    "",
    "commands:",
    "  watch              follow mailboxes with IMAP IDLE",
    "  sync               process existing matching mail once, then exit",
    "  check              verify the config, key and IMAP logins",
    "  login              sign in to an OAuth2 account (device code, no browser)",
    "  encrypt            encrypt an account password with the key in .env",
    "  keygen             create the encryption key in .env",
    "  rules              list the configured keyword rules",
    "  env                show the .env file with values masked",
    "  init               write a starter mails.toml next to the binary",
    "  version            print the version",
    "",
    "options:",
    "  -c, --config PATH  configuration file (default: mails.toml next to the binary)",
    "  -a, --account NAME only this account",
    "      --no-verify    for login: do not test the IMAP connection afterwards",
    "      --once         for watch: process existing mail, then exit",
    "      --write        for encrypt: update mails.toml in place",
    "      --new-key      for encrypt: rotate the key before sealing",
    "  -v, --verbose      debug logging",
    "  -q, --quiet        warnings and errors only",
    "",
    "The config and .env live next to the mails binary, so a single directory",
    "can be copied to another machine and keep working.",
  ]
  for line in lines {
    print_line(line)
  }
}

///|
async fn config_and_env(opts : CliOptions) -> (Config, EnvFile, String) {
  let path = match opts.config {
    Some(value) => value
    None =>
      default_config_path() catch {
        err => raise cli_error(error_message(err))
      }
  }
  let config = load_config(path) catch {
    err => raise cli_error(error_message(err))
  }
  let env = load_env_file(config.env_file) catch {
    _ => ({ path: config.env_file, keys: [], values: [], } : EnvFile)
  }
  let key = match env.get(config.key_env) {
    Some(value) => trim(value)
    None =>
      match @env.get_env_var(config.key_env) {
        Some(value) => trim(value)
        None => ""
      }
  }
  (config, env, key)
}

///|
/// Pick exactly one account by `--account` or by being the only account.
fn pick_account(config : Config, name : String?) -> Account raise {
  match name {
    Some(wanted) => {
      let accounts = selected_accounts(config, Some(wanted)) catch {
        _ => raise cli_error("no account named '" + wanted + "'")
      }
      accounts[0]
    }
    None =>
      if config.accounts.length() == 1 {
        config.accounts[0]
      } else {
        let names = StringBuilder()
        for account in config.accounts {
          if names.to_string() != "" {
            names.write_string(", ")
          }
          names.write_string(account.name)
        }
        raise cli_error(
          "several accounts are configured (" +
          names.to_string() +
          "); pass --account NAME",
        )
      }
  }
}

///|
/// Read one line from standard input (the password prompt).
async fn read_password(prompt : String) -> String {
  @stdio.stderr.write(prompt)
  let line = @stdio.stdin.read_until("\n") catch {
    _ => raise cli_error("cannot read the password from standard input")
  }
  match line {
    None => raise cli_error("no password was provided on standard input")
    Some(text) => {
      let mut value = text
      if value.has_suffix("\r") {
        value = value[0:value.length() - 1].to_owned()
      }
      if value == "" {
        raise cli_error("the password is empty")
      }
      value
    }
  }
}

///|
async fn cmd_encrypt(opts : CliOptions) -> Unit {
  let (config, env, existing_key) = config_and_env(opts)
  let account = pick_account(config, opts.account)
  let mut key = existing_key
  if opts.new_key || key == "" {
    key = generate_key_spec() catch {
      err => raise cli_error(error_message(err))
    }
    set_env_var(config.env_file, config.key_env, key) catch {
      err =>
        raise cli_error(
          "cannot write " + config.env_file + ": " + error_message(err),
        )
    }
    log_info(
      "wrote a new " +
      config.key_env +
      " to " +
      config.env_file +
      (if opts.new_key { " (rotated)" } else { "" }),
    )
  }
  let password = read_password("IMAP password for " + account.name + ": ")
  let envelope = seal_secret(key, password) catch {
    err => raise cli_error(error_message(err))
  }
  if opts.write {
    let text = @fs.read_file(config.path) catch {
      err =>
        raise cli_error(
          "cannot read " + config.path + ": " + error_message(err),
        )
    }
    let source = text.text() catch {
      _ => raise cli_error(config.path + " is not valid UTF-8")
    }
    let updated = update_account_password(source, account.name, envelope) catch {
      err => raise cli_error(error_message(err))
    }
    @fs.write_file(config.path, updated, create_mode=TruncateExisting) catch {
      err =>
        raise cli_error(
          "cannot write " + config.path + ": " + error_message(err),
        )
    }
    print_line(
      "encrypted the password for '" + account.name + "' in " + config.path,
    )
  } else {
    print_line("# password for account '" + account.name + "'")
    print_line("password = \"" + envelope + "\"")
    print_line("")
    print_line(
      "Paste the line above into [accounts." +
      account.name +
      "] of " +
      config.path +
      ", or rerun with --write.",
    )
  }
  if env.values.length() == 0 {
    print_line("The key is stored in " + config.env_file + " (keep it secret).")
  }
}

///|
async fn cmd_keygen(opts : CliOptions) -> Unit {
  let (config, _env, existing) = config_and_env(opts)
  let key = generate_key_spec() catch {
    err => raise cli_error(error_message(err))
  }
  if existing != "" {
    print_line(
      "replacing the existing " +
      config.key_env +
      " in " +
      config.env_file +
      " (values encrypted with the old key can no longer be read)",
    )
  }
  set_env_var(config.env_file, config.key_env, key) catch {
    err =>
      raise cli_error(
        "cannot write " + config.env_file + ": " + error_message(err),
      )
  }
  print_line("wrote " + config.key_env + " to " + config.env_file)
  print_line("Run `mails encrypt --account NAME --write` for each account.")
}

///|
async fn cmd_env(opts : CliOptions) -> Unit {
  let (config, env, _key) = config_and_env(opts)
  print_line("# " + config.env_file)
  print_line(render_env_for_display(env, false))
}

///|
async fn cmd_rules(opts : CliOptions) -> Unit {
  let (config, _env, _key) = config_and_env(opts)
  let accounts = selected_accounts(config, opts.account) catch {
    err => raise cli_error(error_message(err))
  }
  let mut printed = 0
  for account in accounts {
    let rules = merge_rules(config.rules, account.rules)
    for rule in rules {
      printed = printed + 1
      let fields = StringBuilder()
      for field in rule.fields {
        if fields.to_string() != "" {
          fields.write_string(",")
        }
        fields.write_string(field.as_string())
      }
      let scope = if rule.accounts.length() == 0 {
        "all accounts"
      } else {
        rule.accounts.join(", ")
      }
      print_line("[" + account.name + "] " + rule.name)
      print_line("  keywords: " + rule.keywords.join(", "))
      print_line("  fields:   " + fields.to_string())
      print_line(
        "  match:    " + (if rule.require_all { "all" } else { "any" }),
      )
      print_line("  scope:    " + scope)
      print_line(
        "  command:  " +
        (if rule.argv.length() > 0 {
          rule.argv.join(" ")
        } else {
          rule.shell_command
        }),
      )
    }
  }
  if printed == 0 {
    print_line("no rules are configured")
  }
}

///|
async fn cmd_init(opts : CliOptions) -> Unit {
  let path = match opts.config {
    Some(value) => value
    None =>
      default_config_path() catch {
        err => raise cli_error(error_message(err))
      }
  }
  let exists = @fs.exists(path) catch { _ => false }
  if exists {
    raise cli_error(path + " already exists; move it away first")
  }
  @fs.write_file(path, sample_config(), create_mode=CreateNew) catch {
    err => raise cli_error("cannot write " + path + ": " + error_message(err))
  }
  print_line("wrote " + path)
  print_line("Next: edit the [accounts.example] table, then run")
  print_line("  mails encrypt --account example --write")
}

///|
/// Sign in to an OAuth2 account with the device authorization grant.
///
/// Designed for a machine with no browser: it prints a URL and a short code,
/// the user approves them on any device, and this process polls until the
/// provider hands over a token.
async fn cmd_login(opts : CliOptions) -> Unit {
  let (config, _env, key) = config_and_env(opts)
  let accounts = selected_accounts(config, opts.account) catch {
    err => raise cli_error(error_message(err))
  }
  if accounts.length() == 0 {
    raise cli_error("no accounts selected")
  }
  for account in accounts {
    if account.auth is PasswordLogin {
      print_line(
        account.name + ": uses a password, nothing to do (auth = \"password\")",
      )
      continue
    }
    let settings = oauth_settings_for(account, config.dir) catch {
      err => raise cli_error(account.name + ": " + error_message(err))
    }
    let authorization = request_device_code(settings) catch {
      err => raise cli_error(account.name + ": " + error_message(err))
    }
    print_line(account.name + ": sign in to " + settings.provider)
    print_line("  1. open " + authorization.verification_uri)
    if authorization.verification_uri_complete != "" {
      print_line(
        "     (or directly: " + authorization.verification_uri_complete + ")",
      )
    }
    print_line("  2. enter the code: " + authorization.user_code)
    if authorization.message != "" {
      print_line("     " + authorization.message)
    }
    print_line(
      "  waiting up to " +
      (authorization.expires_in_s / 60).to_string() +
      " minutes for approval (Ctrl-C to abort)...",
    )
    let mut polls = 0
    let tokens = poll_device_token(settings, authorization, () => {
      polls = polls + 1
    }) catch {
      err => raise cli_error(account.name + ": " + error_message(err))
    }
    if is_blank(tokens.refresh_token) {
      raise cli_error(
        account.name +
        ": the provider did not return a refresh token; check that 'offline_access' is in oauth_scope",
      )
    }
    if polls > 1 {
      print_line("  approved after " + polls.to_string() + " checks")
    }
    let path = token_path(account, config.dir)
    save_refresh_token(path, account, tokens.refresh_token, key) catch {
      err => raise cli_error(account.name + ": " + error_message(err))
    }
    print_line("  saved the refresh token to " + path)
    // Seed the in-process cache so the verification below does not refresh
    // the token a second time.
    access_token_cache.set(account.name, tokens)
    if opts.no_verify {
      continue
    }
    let failure : Error? = (() => {
      check_account(account, key, config.dir)
      None
    })() catch {
      err => Some(err)
    }
    match failure {
      Some(err) =>
        raise cli_error(
          account.name +
          ": signed in, but IMAP still fails: " +
          error_message(err),
        )
      None => print_line("  IMAP login ok")
    }
  }
}

///|
async fn cmd_check(opts : CliOptions) -> Unit {
  let (config, _env, key) = config_and_env(opts)
  print_line("config: " + config.path)
  print_line("env:    " + config.env_file)
  let mut any_encrypted = false
  for account in config.accounts {
    if needs_key(account.password) {
      any_encrypted = true
    }
  }
  print_line(
    "key:    " +
    (if key != "" {
      "loaded from " + config.key_env
    } else if any_encrypted {
      "missing (run `mails keygen`)"
    } else {
      "not needed (no encrypted passwords)"
    }),
  )
  let accounts = selected_accounts(config, opts.account) catch {
    err => raise cli_error(error_message(err))
  }
  let mut failures = 0
  for account in accounts {
    let failure : Error? = (() => {
      check_account(account, key, config.dir)
      None
    })() catch {
      err => Some(err)
    }
    match failure {
      Some(err) => {
        failures = failures + 1
        print_error(account.name + ": " + error_message(err))
      }
      None => ()
    }
  }
  if failures > 0 {
    raise cli_error(failures.to_string() + " account(s) failed the check")
  }
  print_line("all accounts are reachable")
}

///|
async fn check_account(
  account : Account,
  key : String,
  config_dir : String,
) -> Unit {
  let credential = credential_for(account, config_dir, key) catch {
    err =>
      raise cli_error(
        "cannot prepare credentials for '" +
        account.name +
        "': " +
        error_message(err),
      )
  }
  let client = ImapClient::connect_with(
    account.host,
    account.port,
    account.use_tls,
    account.tls_verify,
    account.username,
    credential,
  )
  let failure : Error? = (() => {
    for mailbox in account.mailboxes {
      let status = client.select_mailbox(mailbox)
      print_line(
        "ok " +
        account.name +
        " / " +
        mailbox +
        " (" +
        status.exists.to_string() +
        " messages, next uid " +
        status.uid_next.to_string() +
        ")",
      )
    }
    None
  })() catch {
    err => Some(err)
  }
  client.close() catch {
    _ => ()
  }
  match failure {
    Some(err) => raise cli_error(error_message(err))
    None => ()
  }
}

///|
async fn cmd_watch(opts : CliOptions) -> Unit {
  let (config, _env, key) = config_and_env(opts)
  if key == "" {
    let mut needs_a_key = false
    for account in config.accounts {
      if needs_key(account.password) {
        needs_a_key = true
      }
    }
    if needs_a_key {
      raise cli_error(
        "no encryption key: set " +
        config.key_env +
        " in " +
        config.env_file +
        " (run `mails keygen`)",
      )
    }
  }
  let accounts = selected_accounts(config, opts.account) catch {
    err => raise cli_error(error_message(err))
  }
  run_watch(config, accounts, key, opts.once)
}

///|
async fn cmd_version() -> Unit {
  print_line("mails " + cli_version)
}

///|
async fn dispatch(opts : CliOptions) -> Unit {
  if opts.help {
    print_help()
    return
  }
  match opts.command {
    "" | "help" => print_help()
    "watch" => cmd_watch(opts)
    "sync" => {
      opts.once = true
      cmd_watch(opts)
    }
    "check" => cmd_check(opts)
    "login" => cmd_login(opts)
    "encrypt" => cmd_encrypt(opts)
    "keygen" => cmd_keygen(opts)
    "rules" => cmd_rules(opts)
    "env" => cmd_env(opts)
    "init" => cmd_init(opts)
    "version" | "--version" => cmd_version()
    other =>
      raise cli_error("unknown command '" + other + "'; try `mails help`")
  }
}

///|
/// Parse arguments, run the command, and report whether it succeeded.
pub async fn main_cli() -> Bool {
  let argv = @env.args()
  let opts = parse_args(argv) catch {
    err => {
      print_error(error_message(err))
      return false
    }
  }
  let failed = (() => {
    dispatch(opts)
    false
  })() catch {
    err => {
      print_error(error_message(err))
      true
    }
  }
  !failed
}
