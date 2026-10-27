///|
/// A `.env` file is the only place the encryption key lives, so reading and
/// rewriting it must not lose other entries.

///|
let env_parse_path : String = "/tmp/mails_env_wbtest_parse.env"

///|
let env_write_path : String = "/tmp/mails_env_wbtest_write.env"

///|
async test "parses quoted, exported and commented values" {
  let source = "# comment\n" +
    "PLAIN=value\n" +
    "export EXPORTED=two\n" +
    "QUOTED=\"with spaces\"\n" +
    "SINGLE='single quoted'\n" +
    "HASH=before # trailing comment\n" +
    "EMPTY=\n"
  @fs.write_file(env_parse_path, source, create_mode=CreateOrTruncate)
  let env = load_env_file(env_parse_path)
  assert_eq(env.get("PLAIN"), Some("value"))
  assert_eq(env.get("EXPORTED"), Some("two"))
  assert_eq(env.get("QUOTED"), Some("with spaces"))
  assert_eq(env.get("SINGLE"), Some("single quoted"))
  assert_eq(env.get("HASH"), Some("before"))
  assert_eq(env.get("EMPTY"), Some(""))
  assert_eq(env.get("MISSING"), None)
}

///|
async test "a missing env file is an empty environment" {
  let env = load_env_file("/tmp/mails_env_wbtest_missing.env")
  assert_eq(env.get("MAILS_KEY"), None)
}

///|
async test "set_env_var adds and replaces without touching other keys" {
  let source = "# keep this\nOTHER=one\n"
  @fs.write_file(env_write_path, source, create_mode=CreateOrTruncate)
  set_env_var(env_write_path, "MAILS_KEY", "b64:first")
  set_env_var(env_write_path, "MAILS_KEY", "b64:second")
  let env = load_env_file(env_write_path)
  assert_eq(env.get("OTHER"), Some("one"))
  assert_eq(env.get("MAILS_KEY"), Some("b64:second"))
  let data = @fs.read_file(env_write_path)
  let text = data.text()
  assert_true(text.contains("# keep this"))
  assert_true(text.contains("MAILS_KEY=b64:second"))
}

///|
test "masks secret values when displaying" {
  let env_text = EnvFile::{
    path: ".env",
    keys: ["MAILS_KEY", "OTHER"],
    values: ["b64:secret", "visible"],
  }
  let shown = render_env_for_display(env_text, false)
  assert_true(shown.contains("MAILS_KEY=***"))
  assert_true(shown.contains("OTHER=visible"))
  assert_false(shown.contains("b64:secret"))
}
