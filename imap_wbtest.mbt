///|
/// Credentials must never reach a log file or the journal, so a rejected
/// command is quoted in its redacted form only.

///|
test "redact_command hides the LOGIN password" {
  let quoted = redact_command(
    "LOGIN \"me@example.com\" \"SI_SECRET_PASSWORD_5F3QK2ZD\"",
  )
  assert_false(quoted.contains("SI_SECRET_PASSWORD_5F3QK2ZD"))
  assert_true(quoted.contains("me@example.com"))
  assert_true(quoted.contains("<redacted>"))
}

///|
test "redact_command hides an AUTHENTICATE initial response" {
  let quoted = redact_command("AUTHENTICATE PLAIN AHVzZXIAcGFzcw==")
  assert_false(quoted.contains("AHVzZXIAcGFzcw=="))
  assert_true(quoted.contains("PLAIN"))
  assert_true(quoted.contains("<redacted>"))
}

///|
test "redact_command keeps non-credential commands intact" {
  assert_eq(redact_command("SELECT \"INBOX\""), "SELECT \"INBOX\"")
  assert_eq(redact_command("CAPABILITY"), "CAPABILITY")
  assert_eq(redact_command("UID SEARCH UID 1:*"), "UID SEARCH UID 1:*")
}

///|
test "redact_command tolerates a password with spaces" {
  let quoted = redact_command("LOGIN user \"pass word with spaces\"")
  assert_false(quoted.contains("pass word"))
  assert_true(quoted.contains("<redacted>"))
}
