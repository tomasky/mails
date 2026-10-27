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
