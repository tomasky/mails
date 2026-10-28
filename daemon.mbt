///| The watch loop: one connection per mailbox, IDLE when available and
/// polling when it is not.

///|
pub struct Runtime {
  account : Account
  rules : Array[Rule]
  config_dir : String
  key : String
  once : Bool
  failed : Ref[Bool]
}

///|
fn merge_rules(global : Array[Rule], account_rule : Array[Rule]) -> Array[Rule] {
  let out : Array[Rule] = []
  for rule in global {
    out.push(rule)
  }
  for rule in account_rule {
    out.push(rule)
  }
  out
}

///|
/// Handle one fetched message: parse, match every rule, run their commands.
async fn handle_message(
  runtime : Runtime,
  mailbox : String,
  fetched : FetchedMessage,
) -> Unit {
  let message = build_message(
    mailbox,
    fetched.uid,
    fetched.size,
    fetched.header,
    fetched.body,
  )
  if is_blank(message.subject) && is_blank(message.body) {
    log_debug("uid " + fetched.uid + " has no text to match")
  }
  let hits = match_rules(runtime.rules, runtime.account.name, mailbox, message)
  if hits.length() == 0 {
    log_debug(
      "uid " +
      fetched.uid +
      " in " +
      mailbox +
      " matched no rule: " +
      truncate_chars(message.subject, 120),
    )
    return
  }
  for hit in hits {
    ignore(run_action(runtime.account.name, mailbox, message, hit))
  }
}

///|
/// Fetch and handle every message newer than `last_uid`.
async fn sync_mailbox(
  runtime : Runtime,
  client : ImapClient,
  mailbox : String,
  last_uid : Int32,
  uid_validity : Int32,
  first_connection : Ref[Bool],
) -> Int32 {
  let from_uid = if last_uid < 0 { 1 } else { last_uid + 1 }
  let uids = client.search_uids(from_uid)
  log_debug(
    "search after uid " +
    from_uid.to_string() +
    " returned " +
    uids.length().to_string() +
    " entries",
  )
  let mut highest = last_uid
  // The search may return the highest existing UID for a `n:*` range; sort
  // numerically so commands run oldest first.
  let ordered : Array[Int32] = []
  for raw in uids {
    let value = @string.parse_int(raw) catch { _ => -1 }
    if value > last_uid {
      ordered.push(value)
    }
  }
  let mut index = 0
  while index < ordered.length() {
    let mut best = index
    let mut scan = index + 1
    while scan < ordered.length() {
      if ordered[scan] < ordered[best] {
        best = scan
      }
      scan = scan + 1
    }
    if best != index {
      let tmp = ordered[index]
      ordered[index] = ordered[best]
      ordered[best] = tmp
    }
    index = index + 1
  }
  log_debug("processing " + ordered.length().to_string() + " new messages")
  let mut fetch_error : Error? = None
  for uid in ordered {
    let uid_text = uid.to_string()
    let fetched = client.fetch_message(uid_text, runtime.account.max_body_bytes) catch {
      err => {
        // A dropped connection is not "this mail is gone": stop the scan so the
        // reconnect retries from the last cursor. Advancing past a message that
        // was never handled would silently lose it.
        log_warn("cannot fetch uid " + uid_text + ": " + err.to_string())
        fetch_error = Some(err)
        None
      }
    }
    if fetch_error is Some(_) {
      break
    }
    match fetched {
      Some(message) =>
        handle_message(runtime, mailbox, message) catch {
          err => log_error("uid " + uid_text + " failed: " + err.to_string())
        }
      // The server answered but has no such message any more.
      None => log_warn("uid " + uid_text + " is no longer available")
    }
    if uid > highest {
      highest = uid
    }
    // Save after every message, not just at the end of the scan: a crash or a
    // dropped connection halfway through must not replay the mail that was
    // already handled.
    save_cursor(
      runtime.config_dir,
      runtime.account.name,
      mailbox,
      uid_validity,
      highest,
    )
    // From the first handled message on, a reconnect resumes from the cursor
    // instead of replaying the mailbox, even with `startup_sync = true`.
    first_connection.val = false
  }
  match fetch_error {
    Some(err) => raise err
    None => ()
  }
  highest
}

///|
/// Run the session body, then always close the connection.
async fn watch_mailbox(
  runtime : Runtime,
  mailbox : String,
  first_connection : Ref[Bool],
) -> Unit {
  let account = runtime.account
  let credential = credential_for(account, runtime.config_dir, runtime.key)
  let client = ImapClient::connect_with(
    account.host,
    account.port,
    account.use_tls,
    account.tls_verify,
    account.username,
    credential,
  )
  let failure : Error? = (() => {
    watch_connected(runtime, mailbox, client, first_connection)
    None
  })() catch {
    err => Some(err)
  }
  client.close() catch {
    _ => ()
  }
  match failure {
    Some(err) => raise err
    None => ()
  }
}

///|
/// The UID to start scanning after, given what the config, the saved cursor
/// and the `SELECT` reply say.
///
/// `first_connection` is the first connection to this mailbox in this process.
/// It follows `startup_sync`, while a reconnect resumes from the saved cursor
/// instead of replaying mail that was already handled: rule commands must not
/// run twice because the connection dropped.
///
/// `None` means "ask the server for the newest UID it already holds", the only
/// case where nothing on disk or in the reply says what was handled before.
fn initial_last_uid(
  startup_sync : Bool,
  first_connection : Bool,
  once : Bool,
  uid_validity : Int32,
  uid_next : Int32,
  saved_uv : Int32,
  saved_last_uid : Int32,
) -> Int32? {
  // `mails sync` scans the whole mailbox; a one-shot run is always full.
  if once || (startup_sync && first_connection) {
    return Some(0)
  }
  // The saved cursor beats `UIDNEXT` on a reconnect: servers that answer
  // `UIDNEXT 0` while mail exists would otherwise force a full rescan and
  // re-run every rule command.
  if !first_connection && saved_last_uid > 0 && saved_uv == uid_validity {
    return Some(saved_last_uid)
  }
  if uid_next > 0 {
    return Some(uid_next - 1)
  }
  None
}

///|
async fn watch_connected(
  runtime : Runtime,
  mailbox : String,
  client : ImapClient,
  first_connection : Ref[Bool],
) -> Unit {
  let account = runtime.account
  let mut status = client.select_mailbox(mailbox)
  let (saved_uv, saved_last_uid) = load_cursor(
    runtime.config_dir,
    account.name,
    mailbox,
  )
  let mut last_uid = match
    initial_last_uid(
      account.startup_sync,
      first_connection.val,
      runtime.once,
      status.uid_validity,
      status.uid_next,
      saved_uv,
      saved_last_uid,
    ) {
    Some(value) => value
    // Nothing says what was handled before and the server does not report
    // `UIDNEXT` either: treat the mail that is already there as seen instead of
    // replaying it.
    None => client.highest_uid()
  }
  log_info(
    "watching " +
    account.name +
    " / " +
    mailbox +
    " (uidvalidity " +
    status.uid_validity.to_string() +
    ", next uid " +
    status.uid_next.to_string() +
    ", handling mail after uid " +
    last_uid.to_string() +
    ")",
  )
  last_uid = sync_mailbox(
    runtime,
    client,
    mailbox,
    last_uid,
    status.uid_validity,
    first_connection,
  )
  // Nothing matched (or the mailbox is empty), but the scan itself is done:
  // record it so a reconnect starts from here.
  save_cursor(
    runtime.config_dir,
    account.name,
    mailbox,
    status.uid_validity,
    last_uid,
  )
  first_connection.val = false
  if runtime.once {
    log_info("sync of " + mailbox + " finished")
    return
  }
  let mut polling = false
  while true {
    let changed = if polling {
      @async.sleep(poll_interval_ms)
      true
    } else {
      client.idle(account.idle_timeout_ms) catch {
        IdleUnsupported => {
          polling = true
          log_info(
            "server does not support IDLE; polling " +
            mailbox +
            " every " +
            format_duration(poll_interval_ms),
          )
          true
        }
        err => raise err
      }
    }
    let next_status = client.select_mailbox(mailbox)
    if next_status.uid_validity != status.uid_validity {
      log_warn(
        "UIDVALIDITY changed for " + mailbox + "; rescanning the mailbox",
      )
      last_uid = 0
    }
    status = next_status
    if changed || status.uid_next - 1 > last_uid {
      last_uid = sync_mailbox(
        runtime,
        client,
        mailbox,
        last_uid,
        status.uid_validity,
        first_connection,
      )
    }
  }
}

///|
let poll_interval_ms : Int32 = 60_000

///|
/// Reconnect forever, with capped exponential backoff.
async fn mailbox_loop(runtime : Runtime, mailbox : String) -> Unit {
  let base_backoff = if runtime.account.reconnect_ms > 0 {
    runtime.account.reconnect_ms
  } else {
    30_000
  }
  let mut backoff = base_backoff
  // Shared with `watch_connected`, which clears it once the mailbox has been
  // scanned and its cursor saved.
  let first_connection : Ref[Bool] = Ref(true)
  while true {
    let started = @async.now()
    let failure : Error? = (() => {
      watch_mailbox(runtime, mailbox, first_connection)
      None
    })() catch {
      err => Some(err)
    }
    match failure {
      None => return
      Some(err) => {
        log_error(
          "[" +
          runtime.account.name +
          " / " +
          mailbox +
          "] " +
          error_message(err),
        )
        if runtime.once {
          runtime.failed.val = true
          return
        }
        // A session that stayed up for a while means the failure is new, not
        // a tight reconnect loop: start the backoff from the configured delay.
        if @async.now() - started > 60_000L {
          backoff = base_backoff
        }
        log_info("reconnecting in " + format_duration(backoff))
        @async.sleep(backoff)
        backoff = if backoff * 2 > 300_000 { 300_000 } else { backoff * 2 }
      }
    }
  }
}

///|
/// Start watching every selected account and mailbox, or sync once.
pub async fn run_watch(
  config : Config,
  accounts : Array[Account],
  key : String,
  once : Bool,
) -> Unit {
  // Warn once at startup: a command that interpolates message text into a
  // shell lets any sender run commands.
  let all_rules : Array[Rule] = []
  for rule in config.rules {
    all_rules.push(rule)
  }
  for account in accounts {
    for rule in account.rules {
      all_rules.push(rule)
    }
  }
  for rule in all_rules {
    if rule.shell_command == "" {
      continue
    }
    let risky = raw_placeholders(rule.shell_command)
    if risky.length() > 0 {
      let advice : Array[String] = []
      for name in risky {
        advice.push(raw_placeholder_advice(name))
      }
      log_warn(
        "rule '" +
        rule.name +
        "' inserts " +
        risky.join(", ") +
        " raw into a shell command, so a sender can run a command through it; " +
        "use " +
        advice.join(" or "),
      )
    }
  }
  let failed : Ref[Bool] = Ref(false)
  @async.with_task_group(group => {
    for account in accounts {
      // Fail fast on a missing password instead of reconnecting forever.
      if account.auth is PasswordLogin {
        if account.password == "" {
          raise MailsError(
            "account '" +
            account.name +
            "' has no password; run `mails encrypt --account " +
            account.name +
            " --write`",
          )
        }
        ignore(resolve_secret(key, account.password))
      }
      let runtime : Runtime = {
        account,
        rules: merge_rules(config.rules, account.rules),
        config_dir: config.dir,
        key,
        once,
        failed,
      }
      for mailbox in account.mailboxes {
        group.spawn_bg(() => mailbox_loop(runtime, mailbox))
      }
    }
  })
  if once && failed.val {
    raise MailsError("one or more mailboxes failed to sync")
  }
}
