///| Keyword matching against a message's subject, body or addresses.

///|
pub struct RuleMatch {
  rule : Rule
  keywords : Array[String]
  fields : Array[String]
}

///|
pub fn rule_applies(rule : Rule, account : String, mailbox : String) -> Bool {
  let mut account_ok = rule.accounts.length() == 0
  for name in rule.accounts {
    if name == account {
      account_ok = true
    }
  }
  let mut mailbox_ok = rule.mailboxes.length() == 0
  for name in rule.mailboxes {
    if name == mailbox {
      mailbox_ok = true
    }
  }
  account_ok && mailbox_ok
}

///|
fn field_text(message : MailMessage, field : MatchField) -> String {
  match field {
    Subject => message.subject
    Body => message.body
    From => message.from
    To => message.to
  }
}

///|
fn keyword_matches(
  keyword : String,
  haystack : String,
  ignore_case : Bool,
  regex : Bool,
) -> Bool {
  if regex {
    let pattern = if ignore_case { "(?i:" + keyword + ")" } else { keyword }
    let compiled = @string.Regex::Regex(pattern) catch { _ => return false }
    match compiled.execute(haystack) {
      Some(_) => true
      None => false
    }
  } else if ignore_case {
    haystack.to_lower().contains(keyword.to_lower())
  } else {
    haystack.contains(keyword)
  }
}

///|
/// Test one rule against one message.
pub fn match_rule(rule : Rule, message : MailMessage) -> RuleMatch? {
  let matched_keywords : Array[String] = []
  let matched_fields : Array[String] = []
  for field in rule.fields {
    let text = field_text(message, field)
    for keyword in rule.keywords {
      if keyword_matches(keyword, text, rule.ignore_case, rule.regex) {
        let mut already = false
        for seen in matched_keywords {
          if seen == keyword {
            already = true
          }
        }
        if !already {
          matched_keywords.push(keyword)
        }
        let mut field_seen = false
        for seen in matched_fields {
          if seen == field.as_string() {
            field_seen = true
          }
        }
        if !field_seen {
          matched_fields.push(field.as_string())
        }
      }
    }
  }
  let hit = if rule.require_all {
    matched_keywords.length() == rule.keywords.length()
  } else {
    matched_keywords.length() > 0
  }
  if hit {
    Some({ rule, keywords: matched_keywords, fields: matched_fields, })
  } else {
    None
  }
}

///|
/// Every rule that fires for `message`, in configuration order.
pub fn match_rules(
  rules : Array[Rule],
  account : String,
  mailbox : String,
  message : MailMessage,
) -> Array[RuleMatch] {
  let out : Array[RuleMatch] = []
  for rule in rules {
    if !rule_applies(rule, account, mailbox) {
      continue
    }
    match match_rule(rule, message) {
      Some(hit) => out.push(hit)
      None => ()
    }
  }
  out
}
