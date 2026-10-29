///|
/// The browsing and sending commands: `ls`, `read` and `send`.
///
/// They share the connection and credential helpers with `watch`, so an account
/// that `mails check` accepts is an account these commands can use. Everything
/// here prints to stdout and exits; none of it touches a cursor or a rule.

///|
/// Options the three new commands need, kept out of `CliOptions` so the watcher
/// path stays untouched.
pub struct MailOptions {
  mut mailbox : String
  mut limit : Int32
  mut unread_only : Bool
  mut folders : Bool
  mut json : Bool
  to : Array[String]
  cc : Array[String]
  bcc : Array[String]
  mut subject : String
  mut body : String?
  mut body_file : String?
  mut html : Bool
  attach : Array[String]
  mut full : Bool
  mut raw : Bool
}

///|
fn default_mail_options() -> MailOptions {
  {
    mailbox: "INBOX",
    limit: 20,
    unread_only: false,
    folders: false,
    json: false,
    to: [],
    cc: [],
    bcc: [],
    subject: "",
    body: None,
    body_file: None,
    html: false,
    attach: [],
    full: false,
    raw: false,
  }
}

///|
/// Parse the options of `ls`, `read` and `send` out of the raw argv.
///
/// Returned together with the positional arguments, because `read` takes a UID
/// and `send` takes none.
fn parse_mail_options(
  argv : Array[String],
) -> (MailOptions, Array[String]) raise {
  let opts = default_mail_options()
  let positionals : Array[String] = []
  let mut index = 0
  while index < argv.length() {
    let arg = argv[index]
    let value = () => {
      index = index + 1
      if index >= argv.length() {
        raise cli_error(arg + " needs a value")
      }
      argv[index]
    }
    if arg == "--mailbox" || arg == "-m" {
      opts.mailbox = value()
    } else if arg == "--limit" || arg == "-n" {
      let raw = value()
      let parsed = @string.parse_int(raw) catch {
        _ => raise cli_error("--limit needs a number, not '" + raw + "'")
      }
      if parsed <= 0 {
        raise cli_error("--limit must be positive")
      }
      opts.limit = parsed
    } else if arg == "--unread" || arg == "-u" || arg == "--unread-only" {
      opts.unread_only = true
    } else if arg == "--folders" || arg == "-f" {
      opts.folders = true
    } else if arg == "--json" {
      opts.json = true
    } else if arg == "--full" {
      opts.full = true
    } else if arg == "--raw" {
      opts.raw = true
    } else if arg == "--to" || arg == "-t" {
      for address in split_addresses(value()) {
        opts.to.push(address)
      }
    } else if arg == "--cc" {
      for address in split_addresses(value()) {
        opts.cc.push(address)
      }
    } else if arg == "--bcc" {
      for address in split_addresses(value()) {
        opts.bcc.push(address)
      }
    } else if arg == "--subject" || arg == "-s" {
      opts.subject = value()
    } else if arg == "--body" || arg == "-b" {
      opts.body = Some(value())
    } else if arg == "--body-file" {
      opts.body_file = Some(value())
    } else if arg == "--html" {
      opts.html = true
    } else if arg == "--attach" || arg == "-a" {
      opts.attach.push(value())
    } else if arg.has_prefix("-") && arg != "-" {
      raise cli_error("unknown option " + arg)
    } else {
      positionals.push(arg)
    }
    index = index + 1
  }
  (opts, positionals)
}

///|
/// Resolve the one account a browsing or sending command works on.
fn single_account(config : Config, name : String?) -> Account raise {
  let accounts = selected_accounts(config, name) catch {
    err => raise cli_error(error_message(err))
  }
  if accounts.length() == 1 {
    return accounts[0]
  }
  let names : Array[String] = []
  for account in accounts {
    names.push(account.name)
  }
  raise cli_error(
    "several accounts match; pass --account (" + names.join(", ") + ")",
  )
}

///|
/// Connect to the account's IMAP server with whatever credential it uses.
async fn open_mailbox(
  account : Account,
  config_dir : String,
  key : String,
  mailbox : String,
) -> (ImapClient, MailboxStatus) {
  let credential = credential_for(account, config_dir, key) catch {
    err => raise cli_error(error_message(err))
  }
  let client = ImapClient::connect_with(
    account.host,
    account.port,
    account.use_tls,
    account.tls_verify,
    account.username,
    credential,
  ) catch {
    err => raise cli_error(error_message(err))
  }
  let status = client.select_mailbox(mailbox) catch {
    err => {
      client.close() catch {
        _ => ()
      }
      raise cli_error(error_message(err))
    }
  }
  (client, status)
}

///|
/// `mails ls` — list folders, or the mail in one folder.
async fn cmd_ls(opts : CliOptions, mail : MailOptions) -> Unit {
  let (config, _env, key) = config_and_env(opts)
  let account = single_account(config, opts.account)
  let credential = credential_for(account, config.dir, key) catch {
    err => raise cli_error(error_message(err))
  }
  let client = ImapClient::connect_with(
    account.host,
    account.port,
    account.use_tls,
    account.tls_verify,
    account.username,
    credential,
  ) catch {
    err => raise cli_error(error_message(err))
  }
  defer (client.close() catch { _ => () })
  if mail.folders {
    let folders = client.list_folders() catch {
      err => raise cli_error(error_message(err))
    }
    if mail.json {
      let items : Array[String] = []
      for folder in folders {
        items.push(
          "{\"name\":\"" +
          json_escape(folder.name) +
          "\",\"delimiter\":\"" +
          json_escape(folder.delimiter) +
          "\",\"selectable\":" +
          (if folder_is_noselect(folder) { "false" } else { "true" }) +
          "}",
        )
      }
      print_line("[" + items.join(",") + "]")
      return
    }
    for folder in folders {
      if folder_is_noselect(folder) {
        continue
      }
      print_line(folder.name)
    }
    return
  }
  ignore(
    client.select_mailbox(mail.mailbox) catch {
      err => raise cli_error(error_message(err))
    },
  )
  let envelopes = client.list_envelopes(mail.limit, mail.unread_only) catch {
    err => raise cli_error(error_message(err))
  }
  if mail.json {
    let items : Array[String] = []
    for envelope in envelopes {
      items.push(
        "{\"uid\":\"" +
        json_escape(envelope.uid) +
        "\",\"date\":\"" +
        json_escape(envelope.date) +
        "\",\"from\":\"" +
        json_escape(envelope.from) +
        "\",\"subject\":\"" +
        json_escape(envelope.subject) +
        "\",\"size\":" +
        envelope.size.to_string() +
        ",\"seen\":" +
        (if envelope.seen { "true" } else { "false" }) +
        ",\"flagged\":" +
        (if envelope.flagged { "true" } else { "false" }) +
        "}",
      )
    }
    print_line("[" + items.join(",") + "]")
    return
  }
  let table = render_envelope_table(envelopes)
  if table == "" {
    print_line("no mail in " + mail.mailbox)
    return
  }
  print_line(table)
}

///|
fn folder_is_noselect(folder : Folder) -> Bool {
  for attribute in folder.attributes {
    if attribute.to_upper() == "\\NOSELECT" {
      return true
    }
  }
  false
}

///|
/// `mails read` — print one message.
async fn cmd_read(opts : CliOptions, mail : MailOptions, uid : String) -> Unit {
  // Check the UID before opening a connection: a typo should not cost a login.
  let parsed = @string.parse_int(uid) catch { _ => 0 }
  if parsed <= 0 {
    raise cli_error("'" + uid + "' is not a message UID; see `mails ls`")
  }
  let (config, _env, key) = config_and_env(opts)
  let account = single_account(config, opts.account)
  let (client, _status) = open_mailbox(account, config.dir, key, mail.mailbox)
  defer (client.close() catch { _ => () })
  let fetched = client.fetch_message(uid, account.max_body_bytes) catch {
    err => raise cli_error(error_message(err))
  }
  let message = match fetched {
    Some(value) => value
    None =>
      raise cli_error("no message with uid " + uid + " in " + mail.mailbox)
  }
  if mail.raw {
    // Everything as the server sent it, for piping into another program.
    @stdio.stdout.write(bytes_to_string_lossy(message.header))
    @stdio.stdout.write(bytes_to_string_lossy(message.body))
    return
  }
  let headers = parse_headers(bytes_to_string_lossy(message.header))
  let body = message_body_text_with_headers(headers, message.body)
  if mail.json {
    print_line(
      "{\"uid\":\"" +
      json_escape(message.uid) +
      "\",\"mailbox\":\"" +
      json_escape(mail.mailbox) +
      "\",\"from\":\"" +
      json_escape(decode_encoded_words(header_value(headers, "from"))) +
      "\",\"to\":\"" +
      json_escape(decode_encoded_words(header_value(headers, "to"))) +
      "\",\"subject\":\"" +
      json_escape(decode_encoded_words(header_value(headers, "subject"))) +
      "\",\"date\":\"" +
      json_escape(header_value(headers, "date")) +
      "\",\"body\":\"" +
      json_escape(body) +
      "\"}",
    )
    return
  }
  print_line("From:    " + decode_encoded_words(header_value(headers, "from")))
  print_line("To:      " + decode_encoded_words(header_value(headers, "to")))
  print_line("Date:    " + header_value(headers, "date"))
  print_line(
    "Subject: " + decode_encoded_words(header_value(headers, "subject")),
  )
  print_line("UID:     " + message.uid + " (" + mail.mailbox + ")")
  print_line("")
  let text = if mail.full { body } else { truncate_chars(body, 4_000) }
  print_line(text)
}

///|
/// Read the message body from `--body`, `--body-file`, or stdin.
///
/// stdin is only read when neither option is given, so `mails send` in a script
/// does not block waiting for input it was never going to get.
async fn read_body(mail : MailOptions) -> String {
  match mail.body {
    Some(text) => return text
    None => ()
  }
  match mail.body_file {
    Some(path) => {
      let data = @fs.read_file(path) catch {
        err => raise cli_error("cannot read " + path + ": " + err.to_string())
      }
      return data.text()
    }
    None => ()
  }
  let data = @stdio.stdin.read_all() catch {
    err =>
      raise cli_error("cannot read the message from stdin: " + err.to_string())
  }
  data.text()
}

///|
/// `mails send` — deliver one message over SMTP.
async fn cmd_send(opts : CliOptions, mail : MailOptions) -> Unit {
  let (config, _env, key) = config_and_env(opts)
  let account = single_account(config, opts.account)
  if is_blank(account.smtp_host) {
    raise cli_error(
      "account '" +
      account.name +
      "' has no smtp_host; add one to send mail (see mails.toml.example)",
    )
  }
  if mail.to.length() == 0 {
    raise cli_error("no recipient; use --to someone@example.com")
  }
  let body = read_body(mail)
  if trim(body) == "" {
    raise cli_error("the message body is empty")
  }
  let attachments : Array[Attachment] = []
  for path in mail.attach {
    let data = @fs.read_file(path) catch {
      err => raise cli_error("cannot read " + path + ": " + err.to_string())
    }
    attachments.push({
      name: path,
      mime: guess_mime_type(path),
      data: data.binary(),
    })
  }
  let from = if is_blank(account.username) {
    raise cli_error(
      "account '" + account.name + "' has no username to send from",
    )
  } else {
    account.username
  }
  let draft : Draft = {
    from,
    to: mail.to,
    cc: mail.cc,
    bcc: mail.bcc,
    subject: mail.subject,
    body,
    html: mail.html,
    attachments,
  }
  let unique = random_token()
  let message = render_outgoing_message(draft, now_seconds(), unique)
  let recipients = draft_recipients(draft)
  let credential = credential_for(account, config.dir, key) catch {
    err => raise cli_error(error_message(err))
  }
  let password = match credential {
    Password(value) => value
    Bearer(_) => ""
  }
  let access_token = match credential {
    Bearer(value) => Some(value)
    Password(_) => None
  }
  let client = SmtpClient::connect(
    account.smtp_host,
    account.smtp_port,
    account.smtp_tls,
    account.smtp_starttls,
    account.smtp_tls_verify,
  ) catch {
    err => raise cli_error(error_message(err))
  }
  let auth = choose_smtp_auth(
    client.capabilities,
    account.smtp_username,
    password,
    access_token,
  )
  client.authenticate(auth) catch {
    err => {
      client.close() catch {
        _ => ()
      }
      raise cli_error(error_message(err))
    }
  }
  client.send({ from, to: recipients, }, string_to_bytes(message)) catch {
    err => {
      client.close() catch {
        _ => ()
      }
      raise cli_error(error_message(err))
    }
  }
  client.close() catch {
    _ => ()
  }
  print_line(
    "sent to " +
    recipients.join(", ") +
    " via " +
    account.smtp_host +
    ":" +
    account.smtp_port.to_string(),
  )
}

///|
/// A short token for `Message-ID` and multipart boundaries, from `/dev/urandom`.
async fn random_token() -> String {
  let bytes = @fs.open("/dev/urandom", mode=ReadOnly) catch {
    _ => return random_fallback()
  }
  defer bytes.close()
  let data = bytes.read_exactly(8) catch { _ => return random_fallback() }
  let digits : Array[Char] = [
    '0', '1', '2', '3', '4', '5', '6', '7', '8', '9', 'a', 'b', 'c', 'd', 'e', 'f',
  ]
  let out = StringBuilder()
  for byte in data {
    let value = byte.to_int()
    out.write_char(digits[value >> 4])
    out.write_char(digits[value & 0xF])
  }
  out.to_string()
}

///|
fn random_fallback() -> String {
  "0000000000000000"
}

///|
/// Seconds since the Unix epoch, which is all a `Date:` header needs.
///
/// The C stub is `mails_unix_time` in `time_stub.c`; it is the only piece of
/// the sender that is not portable MoonBit.
extern "C" fn mails_unix_time() -> Int64 = "mails_unix_time"

///|
fn now_seconds() -> Int64 {
  mails_unix_time()
}
