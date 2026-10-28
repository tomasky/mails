///|
/// The cursor is what keeps a reconnect from re-running rule commands for mail
/// that was already handled, so it has to survive a round trip and stay
/// separate per mailbox.

///|
async test "a saved cursor is loaded back" {
  let dir = @fs.tmpdir(prefix="mails_cursor_wbtest")
  save_cursor(dir, "agt", "INBOX", 1793102629, 42)
  assert_eq(load_cursor(dir, "agt", "INBOX"), (1793102629, 42))
}

///|
async test "a missing cursor file reads as unknown" {
  let dir = @fs.tmpdir(prefix="mails_cursor_wbtest")
  assert_eq(load_cursor(dir, "agt", "INBOX"), (0, 0))
}

///|
async test "each mailbox has its own cursor" {
  let dir = @fs.tmpdir(prefix="mails_cursor_wbtest")
  save_cursor(dir, "agt", "INBOX", 11, 7)
  save_cursor(dir, "agt", "Sent", 11, 3)
  assert_eq(load_cursor(dir, "agt", "INBOX"), (11, 7))
  assert_eq(load_cursor(dir, "agt", "Sent"), (11, 3))
}

///|
async test "each account has its own cursor" {
  let dir = @fs.tmpdir(prefix="mails_cursor_wbtest")
  save_cursor(dir, "one", "INBOX", 11, 7)
  save_cursor(dir, "two", "INBOX", 11, 2)
  assert_eq(load_cursor(dir, "one", "INBOX"), (11, 7))
  assert_eq(load_cursor(dir, "two", "INBOX"), (11, 2))
}

///|
async test "mailbox names that are not file-name safe stay in their own file" {
  let dir = @fs.tmpdir(prefix="mails_cursor_wbtest")
  save_cursor(dir, "agt", "Sent Items/2026", 5, 9)
  let path = cursor_path(dir, "agt", "Sent Items/2026")
  assert_eq(path.has_prefix(dir + "/.agt."), true)
  assert_eq(path.has_suffix(".cursor"), true)
  // The sanitized name carries no path separator, so the cursor cannot land in
  // a subdirectory of the config directory.
  assert_eq(path[dir.length() + 1:].contains("/"), false)
  assert_eq(load_cursor(dir, "agt", "Sent Items/2026"), (5, 9))
}

///|
async test "a corrupt cursor file reads as unknown" {
  let dir = @fs.tmpdir(prefix="mails_cursor_wbtest")
  @fs.write_file(
    cursor_path(dir, "agt", "Junk"),
    "not a cursor\n",
    create_mode=CreateOrTruncate,
  )
  assert_eq(load_cursor(dir, "agt", "Junk"), (0, 0))
}

///|
async test "a cursor saved twice keeps only the newest values" {
  let dir = @fs.tmpdir(prefix="mails_cursor_wbtest")
  save_cursor(dir, "agt", "INBOX", 7, 1)
  save_cursor(dir, "agt", "INBOX", 7, 5)
  assert_eq(load_cursor(dir, "agt", "INBOX"), (7, 5))
}

///|
/// Sanitising the file name turns every unusual character into `_`, so two
/// different mailboxes could land in the same file and overwrite each other's
/// position.
async test "mailboxes that sanitise to the same name get different cursors" {
  let dir = @fs.tmpdir(prefix="mails_cursor_wbtest")
  assert_true(
    cursor_path(dir, "agt", "Sent Items") !=
    cursor_path(dir, "agt", "Sent/Items"),
  )
  save_cursor(dir, "agt", "Sent Items", 11, 7)
  save_cursor(dir, "agt", "Sent/Items", 11, 3)
  assert_eq(load_cursor(dir, "agt", "Sent Items"), (11, 7))
  assert_eq(load_cursor(dir, "agt", "Sent/Items"), (11, 3))
}

///|
async test "accounts that sanitise to the same name get different cursors" {
  let dir = @fs.tmpdir(prefix="mails_cursor_wbtest")
  save_cursor(dir, "a.b", "INBOX", 11, 7)
  save_cursor(dir, "a_b", "INBOX", 11, 3)
  assert_eq(load_cursor(dir, "a.b", "INBOX"), (11, 7))
  assert_eq(load_cursor(dir, "a_b", "INBOX"), (11, 3))
}
