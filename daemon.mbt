///| The watch loop: one connection per mailbox, IDLE when available and
/// polling when it is not.

///|
pub struct Runtime {
  account : Account
  rules : Array[Rule]
  password : String
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
  for uid in ordered {
    let uid_text = uid.to_string()
    let fetched = client.fetch_message(uid_text, runtime.account.max_body_bytes) catch {
      err => {
        log_warn("cannot fetch uid " + uid_text + ": " + err.to_string())
        None
      }
    }
    match fetched {
      Some(message) =>
        handle_message(runtime, mailbox, message) catch {
          err => log_error("uid " + uid_text + " failed: " + err.to_string())
        }
      None => log_warn("uid " + uid_text + " is no longer available")
    }
    if uid > highest {
      highest = uid
    }
  }
  highest
}

///|
/// Run the session body, then always close the connection.
async fn watch_mailbox(runtime : Runtime, mailbox : String) -> Unit {
  let account = runtime.account
  let client = ImapClient::connect(
    account.host,
    account.port,
    account.use_tls,
    account.tls_verify,
    account.username,
    runtime.password,
  )
  let failure : Error? = (() => {
    watch_connected(runtime, mailbox, client)
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
async fn watch_connected(
  runtime : Runtime,
  mailbox : String,
  client : ImapClient,
) -> Unit {
  let account = runtime.account
  let mut status = client.select_mailbox(mailbox)
  // `mails sync` scans the whole mailbox even when startup_sync is off; a
  // one-shot run that skipped everything would be useless.
  let mut last_uid = if account.startup_sync || runtime.once {
    0
  } else if status.uid_next > 0 {
    status.uid_next - 1
  } else {
    0
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
    ")",
  )
  last_uid = sync_mailbox(runtime, client, mailbox, last_uid)
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
      last_uid = sync_mailbox(runtime, client, mailbox, last_uid)
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
  while true {
    let started = @async.now()
    let failure : Error? = (() => {
      watch_mailbox(runtime, mailbox)
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
  let failed : Ref[Bool] = Ref(false)
  @async.with_task_group(group => {
    for account in accounts {
      if account.password == "" {
        raise MailsError(
          "account '" +
          account.name +
          "' has no password; run `mails encrypt --account " +
          account.name +
          " --write`",
        )
      }
      let password = resolve_secret(key, account.password)
      let runtime : Runtime = {
        account,
        rules: merge_rules(config.rules, account.rules),
        password,
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
