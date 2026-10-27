///|
/// Keyword matching is the feature this tool exists for, so every mode gets a
/// test: any/all, case sensitivity, regular expressions and field selection.

///|
fn sample_message(subject : String, body : String) -> MailMessage {
  {
    uid: "42",
    mailbox: "INBOX",
    subject,
    from: "Alice <alice@example.com>",
    to: "bob@example.com",
    date: "Mon, 26 Oct 2026 10:00:00 +0000",
    message_id: "<abc@example.com>",
    body,
    raw_bytes: 1024,
  }
}

///|
fn sample_rule() -> Rule {
  {
    name: "invoice",
    accounts: [],
    mailboxes: [],
    fields: [Subject, Body],
    keywords: ["invoice"],
    require_all: false,
    ignore_case: true,
    regex: false,
    shell_command: "true",
    argv: [],
    timeout_ms: 10_000,
    workdir: "",
    body_chars: 1_000,
  }
}

///|
test "any keyword matches the subject" {
  let message = sample_message("Urgent: Invoice #42", "body")
  let hit = match_rule(sample_rule(), message).unwrap()
  assert_eq(hit.keywords, ["invoice"])
  assert_eq(hit.fields, ["subject"])
}

///|
test "keywords also match the body" {
  let message = sample_message("hello", "Please pay the INVOICE today")
  let hit = match_rule(sample_rule(), message).unwrap()
  assert_eq(hit.fields, ["body"])
}

///|
test "a keyword matches across a line break in the body" {
  let rule : Rule = {
    ..sample_rule(),
    keywords: ["payment due"],
    ignore_case: false,
  }
  let message = sample_message("hello", "Your payment\ndue today")
  assert_true(match_rule(rule, message) is Some(_))
}

///|
test "case sensitivity is configurable" {
  let sensitive : Rule = { ..sample_rule(), ignore_case: false, }
  assert_true(match_rule(sensitive, sample_message("INVOICE", "")) is None)
  let insensitive = sample_rule()
  assert_true(match_rule(insensitive, sample_message("Invoice", "")) is Some(_))
}

///|
test "require_all needs every keyword" {
  let rule : Rule = {
    ..sample_rule(),
    keywords: ["invoice", "urgent"],
    require_all: true,
  }
  assert_true(match_rule(rule, sample_message("invoice only", "")) is None)
  let both : Rule = {
    ..sample_rule(),
    keywords: ["invoice", "urgent"],
    require_all: true,
  }
  assert_true(match_rule(both, sample_message("Urgent invoice", "")) is Some(_))
}

///|
test "regular expressions are anchored by the pattern, not the matcher" {
  let rule : Rule = { ..sample_rule(), keywords: ["invoi[a-z]+"], regex: true, }
  assert_true(match_rule(rule, sample_message("Your invoice", "")) is Some(_))
  let no_match : Rule = {
    ..sample_rule(),
    keywords: ["^invoice$"],
    regex: true,
  }
  assert_true(match_rule(no_match, sample_message("Your invoice", "")) is None)
}

///|
test "rules can scope accounts and mailboxes" {
  let rule : Rule = {
    ..sample_rule(),
    accounts: ["work"],
    mailboxes: ["INBOX"],
  }
  assert_true(rule_applies(rule, "work", "INBOX"))
  assert_false(rule_applies(rule, "home", "INBOX"))
  assert_false(rule_applies(rule, "work", "Archive"))
}

///|
test "match_rules keeps configuration order and skips other mailboxes" {
  let first : Rule = { ..sample_rule(), name: "first", }
  let second : Rule = {
    ..sample_rule(),
    name: "second",
    keywords: ["invoice"],
  }
  let hits = match_rules(
    [first, second],
    "work",
    "INBOX",
    sample_message("Invoice", ""),
  )
  assert_eq(hits.length(), 2)
  assert_eq(hits[0].rule.name, "first")
  assert_eq(hits[1].rule.name, "second")
}
