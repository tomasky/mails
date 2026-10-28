///|
/// Placeholder expansion feeds shell commands, so quoting and unknown names
/// both need defined behaviour.

///|
fn template_context() -> ActionContext {
  let message : MailMessage = {
    uid: "9",
    mailbox: "INBOX",
    subject: "It's an invoice",
    from: "Alice <alice@example.com>",
    to: "bob@example.com",
    date: "Mon, 26 Oct 2026 10:00:00 +0000",
    message_id: "<abc@example.com>",
    body: "line one\nline two",
    raw_bytes: 200,
  }
  let rule : Rule = {
    name: "invoice",
    accounts: [],
    mailboxes: [],
    fields: [Subject],
    keywords: ["invoice"],
    require_all: false,
    ignore_case: true,
    regex: false,
    shell_command: "true",
    argv: [],
    timeout_ms: 1_000,
    workdir: "",
    body_chars: 8,
  }
  { account: "work", mailbox: "INBOX", message, rule, keywords: ["invoice"], }
}

///|
test "expands message placeholders" {
  let context = template_context()
  assert_eq(
    render_template("{{account}}/{{mailbox}} {{uid}}: {{subject}}", context),
    "work/INBOX 9: It's an invoice",
  )
}

///|
test "shell-quoted placeholders are safe" {
  let context = template_context()
  assert_eq(render_template("{{subject_q}}", context), "'It'\\''s an invoice'")
}

///|
test "leaves unknown placeholders visible" {
  let context = template_context()
  assert_eq(render_template("x {{nope}} y", context), "x {{nope}} y")
}

///|
test "truncates the body placeholder" {
  let context = template_context()
  assert_eq(render_template("{{body}}", context), "line one…")
}

///|
test "exports MAILS environment variables" {
  let context = template_context()
  let env = action_env(context)
  assert_eq(env.get("MAILS_SUBJECT"), Some("It's an invoice"))
  assert_eq(env.get("MAILS_UID"), Some("9"))
  assert_eq(env.get("MAILS_RULE"), Some("invoice"))
  assert_eq(env.get("MAILS_BODY_FULL"), Some("line one\nline two"))
}

///|
/// `command` runs under `sh -c`, so these placeholders hand a sender a shell.
test "reports raw message placeholders used in a command" {
  assert_eq(raw_placeholders("cat {{body}}"), ["body"])
  assert_eq(raw_placeholders("echo {{subject}} {{from}}"), ["subject", "from"])
  assert_eq(raw_placeholders("cat {{body_q}} > {{account}}.txt"), [])
  assert_eq(raw_placeholders("notify --title {{subject_q}}"), [])
  assert_eq(raw_placeholders("true"), [])
}

///|
/// Linux rejects a single environment value above 128 KiB, which would stop
/// the command from running at all, so `MAILS_BODY_FULL` is capped.
test "caps the full body exported to the environment" {
  let context = template_context()
  let long : Array[Char] = []
  let mut index = 0
  while index < 200_000 {
    long.push('a')
    index = index + 1
  }
  let message : MailMessage = {
    ..context.message,
    body: String::from_array(long),
  }
  let env = action_env({ ..context, message, })
  let exported = env.get("MAILS_BODY_FULL").unwrap_or("")
  assert_eq(exported.length(), 60_000)
  assert_eq(env.get("MAILS_BODY_TRUNCATED"), Some("1"))
}

///|
test "leaves a short body whole in the environment" {
  let context = template_context()
  let env = action_env(context)
  assert_eq(env.get("MAILS_BODY_FULL"), Some("line one\nline two"))
  assert_eq(env.get("MAILS_BODY_TRUNCATED"), None)
}

///|
test "truncate_bytes keeps utf-8 sequences intact" {
  // Three bytes per character: 60_000 is not a multiple of three.
  let text = String::from_array(Array::make(30_000, '你'))
  let cut = truncate_bytes(text, 60_000)
  assert_eq(string_to_bytes(cut).length() <= 60_000, true)
  assert_eq(cut.length() * 3 <= 60_000, true)
  assert_eq(truncate_bytes("short", 60_000), "short")
}
