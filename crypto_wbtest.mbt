///|
/// The encryption envelope must round-trip and must fail closed with the
/// wrong key.

///|
async test "seals and opens a password" {
  let key = generate_key_spec()
  let password = "p@ss w0rd: \u{fc}nicode"
  let ciphertext = seal_secret(key, password)
  assert_true(is_sealed(ciphertext))
  assert_false(ciphertext.contains(password))
  assert_eq(open_secret(key, ciphertext), password)
}

///|
async test "the same password seals differently every time" {
  let key = generate_key_spec()
  let first = seal_secret(key, "same")
  let second = seal_secret(key, "same")
  assert_true(first != second)
  assert_eq(open_secret(key, first), "same")
  assert_eq(open_secret(key, second), "same")
}

///|
async test "a passphrase key works and reports itself" {
  let key = "pass:correct horse battery staple"
  assert_true(key_uses_passphrase(key))
  let ciphertext = seal_secret(key, "secret")
  assert_eq(open_secret(key, ciphertext), "secret")
  assert_false(key_uses_passphrase(generate_key_spec()))
}

///|
async test "a wrong key is rejected instead of returning garbage" {
  let ciphertext = seal_secret(generate_key_spec(), "secret")
  let result : String? = (() => {
    ignore(open_secret(generate_key_spec(), ciphertext))
    None
  })() catch {
    err => Some(error_message(err))
  }
  assert_true(result.unwrap().contains("wrong encryption key"))
}

///|
async test "resolve_secret leaves plain values alone" {
  assert_eq(resolve_secret("ignored", "plain"), "plain")
  assert_false(needs_key("plain"))
  assert_true(needs_key("enc:v1:x:y:z"))
}
