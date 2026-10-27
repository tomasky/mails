///| `run_action` is the last step before a rule command sees a message, so the
/// environment it exports is checked through a real child process.

///|
async test "a rule command receives the body with its line breaks" {
  let header = string_to_bytes(
    "Content-Type: text/plain; charset=utf-8\r\n\r\n",
  )
  let body = string_to_bytes("first line\r\nsecond line\r\n")
  let message = build_message("INBOX", "12", 40, header, body)
  assert_eq(message.body, "first line\nsecond line")
  let rule : Rule = {
    name: "notify",
    accounts: [],
    mailboxes: [],
    fields: [Body],
    keywords: ["second"],
    require_all: false,
    ignore_case: true,
    regex: false,
    // Fails unless the child sees "second line" on a line of its own.
    shell_command: "printf '%s\\n' \"$MAILS_BODY\" | grep -q '^second line$'",
    argv: [],
    timeout_ms: 5_000,
    workdir: "",
    body_chars: 1_000,
  }
  let hit : RuleMatch = { rule, keywords: ["second"], fields: ["body"], }
  let outcome = run_action("work", "INBOX", message, hit)
  assert_eq(outcome.exit_code, 0)
}
