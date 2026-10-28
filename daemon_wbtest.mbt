///|
/// Where the first scan starts decides whether a reconnect re-runs rule
/// commands for mail that was already handled, so every branch is pinned down
/// here.

///| `initial_last_uid(startup_sync, first_connection, once, uv, uid_next, saved_uv, saved_last_uid)`.

///|
test "a reconnect resumes from the saved cursor even when uid_next is 0" {
  assert_eq(
    initial_last_uid(false, false, false, 1793102629, 0, 1793102629, 5),
    Some(5),
  )
}

///|
test "a reconnect resumes from the saved cursor when uid_next works too" {
  assert_eq(initial_last_uid(false, false, false, 11, 4, 11, 2), Some(2))
}

///|
test "the first connection of a process ignores the cursor" {
  // Startup semantics are documented in terms of the process, not of whatever
  // a previous run left on disk.
  assert_eq(initial_last_uid(false, true, false, 11, 4, 11, 2), Some(3))
}

///|
test "without a cursor a reconnect resumes at uid_next - 1" {
  assert_eq(initial_last_uid(false, false, false, 11, 4, 0, 0), Some(3))
}

///|
test "a cursor from a different uid space is ignored" {
  // A recreated mailbox has a new UIDVALIDITY, so its UIDs cannot be compared
  // with the saved ones.
  assert_eq(initial_last_uid(false, false, false, 99, 4, 11, 2), Some(3))
}

///|
test "without a cursor or uid_next the server has to report the newest uid" {
  assert_eq(initial_last_uid(false, false, false, 11, 0, 0, 0), None)
  assert_eq(initial_last_uid(false, true, false, 11, 0, 0, 0), None)
}

///|
test "startup_sync scans the whole mailbox on the first connection" {
  assert_eq(initial_last_uid(true, true, false, 11, 4, 11, 2), Some(0))
}

///|
test "a reconnect does not replay the mailbox a startup_sync run scanned" {
  assert_eq(initial_last_uid(true, false, false, 11, 0, 11, 2), Some(2))
}

///|
test "mails sync always scans the whole mailbox" {
  assert_eq(initial_last_uid(false, false, true, 11, 4, 11, 2), Some(0))
  assert_eq(initial_last_uid(true, true, true, 11, 4, 11, 2), Some(0))
}

///|
/// A scripted IMAP server: enough of the protocol for `watch_connected` to
/// select a mailbox, search it and fetch messages. It reports `UIDNEXT 0` and
/// answers `UID SEARCH UID n:*` with every UID, which is what the server in the
/// duplicate-trigger report did.

///|
let fixture_uid_validity : Int32 = 1793102629

///|
struct FakeImap {
  mut fetches : Int32
  /// Whether the "new mail" that wakes an `IDLE` up has already been pushed.
  mut delivered : Bool
  /// Drop the connection instead of answering this FETCH, to model a link that
  /// dies mid-scan. `0` disables it.
  mut drop_at_fetch : Int32
}

///|
/// The messages the fake server holds. UID 3 is the mail that arrives while the
/// client watches: a GB2312 quoted-printable body, the charset that turned into
/// mojibake in the report. UIDs 1 and 2 are the mail that is already there.
fn fake_imap_message(uid : String) -> (Bytes, Bytes) {
  if uid == "3" {
    (
      string_to_bytes(
        "Subject: =?gb2312?B?xOO6w6OsysC95w==?=\r\n" +
        "Content-Type: text/plain; charset=gb2312\r\n" +
        "Content-Transfer-Encoding: quoted-printable\r\n\r\n",
      ),
      string_to_bytes("=C4=E3=BA=C3"),
    )
  } else {
    (
      string_to_bytes(
        "Subject: Invoice " +
        uid +
        "\r\n" +
        "Content-Type: text/plain; charset=utf-8\r\n" +
        "Content-Transfer-Encoding: base64\r\n\r\n",
      ),
      string_to_bytes(base64_encode(string_to_bytes("payment due")) + "\r\n"),
    )
  }
}

///|
/// Answer one client until it asks for `IDLE` or `LOGOUT`.
async fn fake_imap_serve(tcp : @socket.Tcp, state : FakeImap) -> Unit {
  tcp.write(string_to_bytes("* OK fake mails ready\r\n"))
  while true {
    let line = match tcp.read_until("\r\n") {
      Some(value) => value
      None => {
        tcp.close()
        return
      }
    }
    let (tag, command) = match line.find(" ") {
      Some(index) => (line[0:index].to_owned(), line[index + 1:].to_owned())
      None => (line, "")
    }
    let upper = command.to_upper()
    if upper.has_prefix("CAPABILITY") {
      tcp.write(
        string_to_bytes(
          "* CAPABILITY IMAP4rev1 IDLE\r\n" +
          tag +
          " OK CAPABILITY completed\r\n",
        ),
      )
    } else if upper.has_prefix("LOGIN") {
      tcp.write(string_to_bytes(tag + " OK LOGIN completed\r\n"))
    } else if upper.has_prefix("SELECT") {
      tcp.write(
        string_to_bytes(
          "* 2 EXISTS\r\n" +
          "* OK [UIDVALIDITY " +
          fixture_uid_validity.to_string() +
          "] UIDs valid\r\n" +
          // The server in the report answers UIDNEXT 0 even though mail exists.
          "* OK [UIDNEXT 0] Predicted next UID\r\n" +
          tag +
          " OK [READ-WRITE] SELECT completed\r\n",
        ),
      )
    } else if upper.has_prefix("UID SEARCH") {
      // Every UID, whatever the range: the client has to filter out what it
      // already handled.
      let uids = if state.delivered { "1 2 3" } else { "1 2" }
      tcp.write(
        string_to_bytes(
          "* SEARCH " + uids + "\r\n" + tag + " OK SEARCH completed\r\n",
        ),
      )
    } else if upper.has_prefix("UID FETCH") {
      state.fetches = state.fetches + 1
      if state.drop_at_fetch != 0 && state.fetches >= state.drop_at_fetch {
        // The link died halfway through the scan.
        tcp.close()
        return
      }
      let mut uid = "0"
      let mut index = 0
      for piece in command.split(" ") {
        if index == 2 {
          uid = piece.to_owned()
        }
        index = index + 1
      }
      let (header, body) = fake_imap_message(uid)
      tcp.write(
        string_to_bytes(
          "* 1 FETCH (UID " +
          uid +
          " RFC822.SIZE " +
          (header.length() + body.length()).to_string() +
          " BODY[HEADER] {" +
          header.length().to_string() +
          "}\r\n",
        ),
      )
      tcp.write(header)
      tcp.write(
        string_to_bytes(
          " BODY[TEXT]<0> {" + body.length().to_string() + "}\r\n",
        ),
      )
      tcp.write(body)
      tcp.write(string_to_bytes(")\r\n" + tag + " OK FETCH completed\r\n"))
    } else if upper.has_prefix("IDLE") {
      tcp.write(string_to_bytes("+ idling\r\n"))
      if state.delivered {
        // A later IDLE stands for the connection dropping, so the watch loop
        // fails fast and reconnects.
        tcp.close()
        return
      }
      // Wake the client up with the message that just arrived, then finish the
      // IDLE exchange properly.
      state.delivered = true
      tcp.write(string_to_bytes("* 3 EXISTS\r\n"))
      let mut done = false
      while !done {
        match tcp.read_until("\r\n") {
          Some(value) => if value.to_upper().has_prefix("DONE") { done = true }
          None => {
            tcp.close()
            return
          }
        }
      }
      tcp.write(string_to_bytes(tag + " OK IDLE completed\r\n"))
    } else if upper.has_prefix("LOGOUT") {
      tcp.write(string_to_bytes("* BYE\r\n" + tag + " OK LOGOUT completed\r\n"))
      tcp.close()
      return
    } else {
      tcp.write(string_to_bytes(tag + " OK completed\r\n"))
    }
  }
}

///|
fn fixture_account(port : Int32) -> Account {
  {
    name: "agt",
    host: "127.0.0.1",
    port,
    username: "user",
    password: "plain-pass",
    use_tls: false,
    tls_verify: false,
    auth: PasswordLogin,
    oauth_provider: "",
    oauth_client_id: "",
    oauth_tenant: "",
    oauth_scope: "",
    oauth_device_endpoint: "",
    oauth_token_endpoint: "",
    oauth_token_file: "",
    mailboxes: ["INBOX"],
    rules: [],
    startup_sync: false,
    idle_timeout_ms: 500,
    reconnect_ms: 100,
    max_body_bytes: 262_144,
  }
}

///|
/// A rule that records every message it matches, with the decoded body text.
fn fixture_rule(hits_path : String) -> Rule {
  {
    name: "fixture",
    accounts: [],
    mailboxes: [],
    fields: [Body],
    keywords: ["你好", "payment due"],
    require_all: false,
    ignore_case: false,
    regex: false,
    shell_command: "",
    argv: ["/bin/sh", "-c", "printf '%s\\n' {{body_q}} >> " + hits_path],
    timeout_ms: 10_000,
    workdir: "",
    body_chars: 4_000,
  }
}

///|
async fn fixture_client(port : Int32) -> ImapClient {
  ImapClient::connect_with(
    "127.0.0.1",
    port,
    false,
    false,
    "user",
    Password("plain-pass"),
  )
}

///|
async fn fixture_hits_text(path : String) -> String {
  @fs.read_file(path).text() catch {
    _ => ""
  }
}

///|
/// A fake server plus the connection counter a test asserts on.

///|
struct FakeImapServer {
  server : @socket.TcpServer
  port : Int32
  state : FakeImap
}

///|
async fn fake_imap_start() -> FakeImapServer {
  let server = @socket.TcpServer(@socket.Addr::resolve("127.0.0.1", port=0))
  {
    server,
    port: server.addr.port(),
    state: { fetches: 0, delivered: false, drop_at_fetch: 0, },
  }
}

///|
async fn fake_imap_accept(fx : FakeImapServer, sessions : Int32) -> Unit {
  let mut session = 0
  while session < sessions {
    let (tcp, _) = fx.server.accept()
    fake_imap_serve(tcp, fx.state)
    session = session + 1
  }
}

///|
/// One watch session against the fake server. `dropped` records whether the
/// session ended with a connection failure, which is what a reconnect follows.
async fn fixture_session(
  fx : FakeImapServer,
  dir : String,
  rules : Array[Rule],
  once : Bool,
  startup_sync : Bool,
  first_connection : Ref[Bool],
) -> Bool {
  let mut account = fixture_account(fx.port)
  account = { ..account, startup_sync, }
  let runtime : Runtime = {
    account,
    rules,
    config_dir: dir,
    key: "",
    once,
    failed: Ref(false),
  }
  let client = fixture_client(fx.port)
  let failure : Error? = (() => {
    watch_connected(runtime, "INBOX", client, first_connection)
    None
  })() catch {
    err => Some(err)
  }
  client.close() catch {
    _ => ()
  }
  failure is Some(_)
}

///|
/// The reported loop: the server answers `UIDNEXT 0`, the connection drops, and
/// the next session re-runs every rule command for mail that was already
/// handled. The saved cursor has to stop that, and the GB2312 body of the mail
/// that arrives while watching has to reach the command as readable text rather
/// than mojibake.
async test "a reconnect does not replay mail that was already handled" {
  // The scripted server drives the real watch loop, so keep its logs out of
  // the test output.
  set_log_level(Quiet)
  let dir = @fs.tmpdir(prefix="mails_daemon_wbtest")
  let hits = dir + "/hits"
  let rules = [fixture_rule(hits)]
  let fx = fake_imap_start()
  @async.with_task_group(group => {
    group.spawn_bg(() => fake_imap_accept(fx, 2))
    // `mailbox_loop` shares this flag with every connection it opens.
    let first_connection : Ref[Bool] = Ref(true)
    // The watch session handles the mail that arrives while it is connected,
    // then dies when the connection drops.
    let dropped = fixture_session(
      fx, dir, rules, false, false, first_connection,
    )
    assert_eq(dropped, true)
    let handled = fixture_hits_text(hits) catch { _ => "" }
    assert_eq(fx.state.fetches, 1)
    // `{{body_q}}` is shell-quoted, so the shell hands the command the decoded
    // body without the quotes.
    assert_eq(handled, "你好\n")
    assert_eq(load_cursor(dir, "agt", "INBOX"), (fixture_uid_validity, 3))
    // The daemon reconnects to the same mailbox: the cursor has to keep it from
    // fetching anything again.
    let dropped_again = fixture_session(
      fx, dir, rules, false, false, first_connection,
    )
    assert_eq(dropped_again, true)
    assert_eq(fx.state.fetches, 1)
    assert_eq(fixture_hits_text(hits) catch { _ => "" }, handled)
  })
  fx.server.close()
}

///|
/// The other way the report can be reproduced: with `startup_sync` on, every
/// reconnect used to scan the whole mailbox again. Only the first connection of
/// the process may do that.
async test "a reconnecting startup_sync run does not rescan the mailbox" {
  set_log_level(Quiet)
  let dir = @fs.tmpdir(prefix="mails_daemon_wbtest")
  let hits = dir + "/hits"
  let rules = [fixture_rule(hits)]
  let fx = fake_imap_start()
  @async.with_task_group(group => {
    group.spawn_bg(() => fake_imap_accept(fx, 2))
    let first_connection : Ref[Bool] = Ref(true)
    // The first connection scans the two messages that are already there plus
    // the one that arrives while it watches.
    ignore(fixture_session(fx, dir, rules, false, true, first_connection))
    assert_eq(fx.state.fetches, 3)
    ignore(fixture_session(fx, dir, rules, false, true, first_connection))
    assert_eq(fx.state.fetches, 3)
  })
  fx.server.close()
}

///|
/// A link that dies in the middle of a scan must not be mistaken for "the rest
/// of the mailbox was handled": the reconnect has to fetch the message that
/// failed, and the cursor has to stop at the last one that really ran.
async test "a scan that dies halfway resumes at the message that failed" {
  set_log_level(Quiet)
  let dir = @fs.tmpdir(prefix="mails_daemon_wbtest")
  let hits = dir + "/hits"
  let rules = [fixture_rule(hits)]
  let fx = fake_imap_start()
  @async.with_task_group(group => {
    group.spawn_bg(() => fake_imap_accept(fx, 2))
    let first_connection : Ref[Bool] = Ref(true)
    // `startup_sync` makes the first session scan uids 1, 2 and 3; the link
    // dies while the second message is being fetched.
    fx.state.drop_at_fetch = 2
    let dropped = fixture_session(fx, dir, rules, false, true, first_connection)
    assert_eq(dropped, true)
    // Only uid 1 was handled, so the cursor must stop there.
    assert_eq(load_cursor(dir, "agt", "INBOX"), (fixture_uid_validity, 1))
    assert_eq(first_connection.val, false)
    let handled = fixture_hits_text(hits)
    assert_eq(handled, "payment due\n")
    // The reconnect picks up at uid 2 instead of rescanning from the start.
    fx.state.drop_at_fetch = 0
    ignore(fixture_session(fx, dir, rules, false, true, first_connection))
    assert_eq(
      fixture_hits_text(hits),
      "payment due\n" + "payment due\n" + "你好\n",
    )
  })
  fx.server.close()
}
