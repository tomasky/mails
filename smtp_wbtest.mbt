///|
test "smtp_plain_response is the base64 of the SASL PLAIN payload" {
  // RFC 4616: an empty authzid, so the payload starts with a NUL byte.
  let encoded = smtp_plain_response("me@example.com", "pw")
  assert_eq(encoded, "AG1lQGV4YW1wbGUuY29tAHB3")
  assert_eq(
    bytes_to_string_lossy(base64_decode(encoded)),
    "\u{0}me@example.com\u{0}pw",
  )
}

///|
test "smtp_has_capability matches whole names only" {
  let capabilities = ["AUTH", "PLAIN", "LOGIN", "SIZE", "STARTTLS"]
  assert_true(smtp_has_capability(capabilities, "STARTTLS"))
  assert_true(smtp_has_capability(capabilities, "starttls"))
  assert_false(smtp_has_capability(capabilities, "START"))
  assert_false(smtp_has_capability(capabilities, "DSN"))
}

///|
/// What a mechanism choice resolved to, as a short name for assertions.
fn auth_name(auth : SmtpAuth) -> String {
  match auth {
    SmtpAuthNone => "none"
    SmtpAuthPlain(_, _) => "plain"
    SmtpAuthLogin(_, _) => "login"
    SmtpAuthXoauth2(_, _) => "xoauth2"
  }
}

///|
test "choose_smtp_auth prefers the token when the server speaks XOAUTH2" {
  let all = ["AUTH", "PLAIN", "LOGIN", "XOAUTH2"]
  assert_eq(auth_name(choose_smtp_auth(all, "u", "p", Some("t"))), "xoauth2")
  assert_eq(auth_name(choose_smtp_auth(all, "u", "p", None)), "plain")
  // A token must not be sent to a server that does not understand it.
  let plain_login = ["AUTH", "PLAIN", "LOGIN"]
  assert_eq(
    auth_name(choose_smtp_auth(plain_login, "u", "p", Some("t"))),
    "plain",
  )
  assert_eq(
    auth_name(choose_smtp_auth(["AUTH", "LOGIN"], "u", "p", None)),
    "login",
  )
  // Nothing advertised: try PLAIN, which is what local relays expect.
  assert_eq(auth_name(choose_smtp_auth([], "u", "p", None)), "plain")
  // No credentials at all.
  assert_eq(auth_name(choose_smtp_auth(all, "u", "", None)), "none")
}

///|
test "validate_address accepts the usual forms" {
  assert_eq(validate_address("me@example.com"), "me@example.com")
  assert_eq(validate_address(" me@example.com "), "me@example.com")
  assert_eq(
    validate_address("me+tag@sub.example.co.uk"),
    "me+tag@sub.example.co.uk",
  )
  // A display name is fine; the bare address is what RCPT TO needs.
  assert_eq(validate_address("First Last <me@example.com>"), "me@example.com")
  assert_eq(
    validate_address("\"Last, First\" <me@example.com>"),
    "me@example.com",
  )
}

///|
test "validate_address rejects header injection and garbage" {
  let bad = [
    "", "no-at-sign", "a@b@c", "me@example.com\r\nBcc: evil@example.com", "me@example.com\n",
    "<>", "<a@b.co", "me@exa mple.com",
  ]
  for address in bad {
    let rejected = try {
      ignore(validate_address(address))
      false
    } catch {
      _ => true
    }
    assert_true(rejected)
  }
}

///|
test "split_addresses splits on commas and semicolons" {
  assert_eq(split_addresses("a@b.co"), ["a@b.co"])
  assert_eq(split_addresses("a@b.co, c@d.co;e@f.co"), [
    "a@b.co", "c@d.co", "e@f.co",
  ])
  assert_eq(split_addresses("  a@b.co  ,  "), ["a@b.co"])
  // An empty value is a caller bug, not an empty recipient list.
  let rejected = try {
    ignore(split_addresses(""))
    false
  } catch {
    _ => true
  }
  assert_true(rejected)
  // One bad address rejects the whole list rather than silently dropping it.
  let rejected = try {
    split_addresses("a@b.co, oops") |> ignore
    false
  } catch {
    _ => true
  }
  assert_true(rejected)
}

///|
test "dot_stuff_bytes normalises line endings and escapes dots" {
  let stuffed = dot_stuff_bytes(b"one\r\ntwo\n.three\r\n")
  // No trailing CRLF: `send` appends the terminator itself.
  assert_eq(bytes_to_string_lossy(stuffed), "one\r\ntwo\r\n..three")
}

///|
test "dot_stuff_bytes leaves text without leading dots alone" {
  assert_eq(bytes_to_string_lossy(dot_stuff_bytes(b"plain")), "plain")
  assert_eq(bytes_to_string_lossy(dot_stuff_bytes(b"")), "")
}

///|
test "dot_stuff_bytes keeps a lone dot on its own line legal" {
  // A body line of "." would otherwise end the DATA section early.
  assert_eq(bytes_to_string_lossy(dot_stuff_bytes(b".")), "..")
}
