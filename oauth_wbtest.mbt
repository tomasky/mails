///|
test "xoauth2 initial response encodes the SASL payload" {
  let payload = xoauth2_initial_response("me@example.com", "tok")
  let expected = base64_encode(
    string_to_bytes("user=me@example.com\u{1}auth=Bearer tok\u{1}\u{1}"),
  )
  assert_eq(payload, expected)
  assert_eq(
    bytes_to_string_lossy(base64_decode(payload)),
    "user=me@example.com\u{1}auth=Bearer tok\u{1}\u{1}",
  )
}

///|
test "xoauth2 initial response keeps unusual characters intact" {
  let payload = xoauth2_initial_response("a+b/c@example.com", "t.o/k=")
  let decoded = bytes_to_string_lossy(base64_decode(payload))
  assert_eq(decoded, "user=a+b/c@example.com\u{1}auth=Bearer t.o/k=\u{1}\u{1}")
}

///|
test "form_escape escapes reserved characters" {
  assert_eq(form_escape("a b"), "a+b")
  assert_eq(form_escape("a+b"), "a%2Bb")
  assert_eq(form_escape("a&b=c"), "a%26b%3Dc")
  assert_eq(form_escape("&/?#"), "%26%2F%3F%23")
  assert_eq(form_escape("-._~AZ09"), "-._~AZ09")
}

///|
test "form_encode joins pairs with an ampersand" {
  assert_eq(
    form_encode([("grant_type", "refresh_token"), ("a b", "c/d")]),
    "grant_type=refresh_token&a+b=c%2Fd",
  )
  assert_eq(form_encode([]), "")
}

///|
test "json helpers read nested fields" {
  let json = @json.parse(
    (
      #|{"s":"text","n":42,"d":3.5,"t":true,"nil":null,"o":{"b":"deep"}}
    ),
  )
  assert_eq(json_field_string(json, "s"), Some("text"))
  assert_eq(json_field_string(json, "o.b"), None)
  assert_eq(json_field_int(json, "n"), Some(42))
  assert_eq(json_field_string(json, "missing"), None)
  assert_eq(json_field_string(json, "n"), None)
  assert_eq(json_field_string(json, "d"), None)
  assert_true(json_field(json, "t") is Some(True))
  assert_true(json_field(json, "nil") is Some(Null))
}

///|
test "json string values are unescaped" {
  let json = @json.parse("{\"s\":\"line\\nquote\\\"tab\\t\"}")
  assert_eq(json_field_string(json, "s"), Some("line\nquote\"tab\t"))
}

///|
test "json_escape round-trips through the json parser" {
  let raw = "a\"b\\c\nd\te"
  let parsed = @json.parse("{\"s\":\"" + json_escape(raw) + "\"}")
  assert_eq(json_field_string(parsed, "s"), Some(raw))
}

///|
test "microsoft defaults are complete" {
  let (device, token, scope) = oauth_provider_defaults("microsoft", "")
  assert_true(device.contains("login.microsoftonline.com"))
  assert_true(device.contains("/devicecode"))
  assert_true(token.contains("/token"))
  assert_true(scope.contains("offline_access"))
  assert_true(scope.contains("IMAP.AccessAsUser.All"))
}

///|
test "microsoft tenant is honoured" {
  let (device, token, _) = oauth_provider_defaults("microsoft", "consumers")
  assert_true(device.contains("/consumers/"))
  assert_true(token.contains("/consumers/"))
  let (common, _, _) = oauth_provider_defaults("microsoft", "")
  assert_true(common.contains("/common/"))
}

///|
test "google defaults use the device endpoint and mail scope" {
  let (device, token, scope) = oauth_provider_defaults("google", "")
  assert_true(device.contains("oauth2.googleapis.com/device/code"))
  assert_true(token.contains("oauth2.googleapis.com/token"))
  assert_true(scope.contains("mail.google.com"))
}

///|
test "unknown provider is rejected" {
  let failure : Error? = (() => {
    ignore(oauth_provider_defaults("yahoo", ""))
    None
  })() catch {
    err => Some(err)
  }
  assert_true(failure is Some(_))
  match failure {
    Some(err) => assert_true(error_message(err).contains("yahoo"))
    None => ()
  }
}
