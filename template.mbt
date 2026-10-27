///| Placeholder and environment expansion for rule actions.
///
/// A command may contain `{{name}}` placeholders; each is replaced by the
/// matching message value. The same values are exported to the child process
/// as `MAILS_*` environment variables, which is the safe way to pass a subject
/// into a shell: `{{subject}}` is inserted raw, while `{{subject_q}}` is
/// single-quoted for POSIX shells.

///|
pub struct ActionContext {
  account : String
  mailbox : String
  message : MailMessage
  rule : Rule
  keywords : Array[String]
}

///|
fn placeholder_value(context : ActionContext, name : String) -> String? {
  let message = context.message
  match name {
    "account" => Some(context.account)
    "mailbox" => Some(context.mailbox)
    "uid" => Some(message.uid)
    "subject" => Some(message.subject)
    "from" => Some(message.from)
    "to" => Some(message.to)
    "date" => Some(message.date)
    "message_id" | "message-id" => Some(message.message_id)
    "body" => Some(truncate_chars(message.body, context.rule.body_chars))
    "rule" => Some(context.rule.name)
    "keywords" => Some(context.keywords.join(", "))
    "fields" =>
      Some(
        {
          let out = StringBuilder()
          let mut first = true
          for field in context.rule.fields {
            if !first {
              out.write_char(',')
            }
            out.write_string(field.as_string())
            first = false
          }
          out.to_string()
        },
      )
    "account_q" => Some(shell_quote(context.account))
    "mailbox_q" => Some(shell_quote(context.mailbox))
    "uid_q" => Some(shell_quote(message.uid))
    "subject_q" => Some(shell_quote(message.subject))
    "from_q" => Some(shell_quote(message.from))
    "to_q" => Some(shell_quote(message.to))
    "date_q" => Some(shell_quote(message.date))
    "body_q" =>
      Some(shell_quote(truncate_chars(message.body, context.rule.body_chars)))
    "rule_q" => Some(shell_quote(context.rule.name))
    _ => None
  }
}

///|
/// Expand every `{{name}}` placeholder in `template`.
pub fn render_template(template : String, context : ActionContext) -> String {
  let out = StringBuilder()
  let mut rest = template
  let mut attempts = 0
  while attempts < 256 {
    attempts = attempts + 1
    match rest.find("{{") {
      None => {
        out.write_string(rest)
        break
      }
      Some(start) => {
        out.write_string(rest[0:start].to_owned())
        let after = rest[start + 2:].to_owned()
        match after.find("}}") {
          None => {
            out.write_string(rest[start:].to_owned())
            break
          }
          Some(end) => {
            let name = trim(after[0:end].to_owned())
            match placeholder_value(context, name) {
              Some(value) => out.write_string(value)
              None =>
                out.write_string(rest[start:start + 2 + end + 2].to_owned())
            }
            rest = after[end + 2:].to_owned()
          }
        }
      }
    }
  }
  out.to_string()
}

///|
/// Environment variables exported to a rule command.
pub fn action_env(context : ActionContext) -> Map[String, String] {
  let env : Map[String, String] = Map([])
  let message = context.message
  env.set("MAILS_ACCOUNT", context.account)
  env.set("MAILS_MAILBOX", context.mailbox)
  env.set("MAILS_UID", message.uid)
  env.set("MAILS_SUBJECT", message.subject)
  env.set("MAILS_FROM", message.from)
  env.set("MAILS_TO", message.to)
  env.set("MAILS_DATE", message.date)
  env.set("MAILS_MESSAGE_ID", message.message_id)
  env.set("MAILS_RULE", context.rule.name)
  env.set("MAILS_KEYWORDS", context.keywords.join(", "))
  env.set("MAILS_BODY", truncate_chars(message.body, context.rule.body_chars))
  env.set("MAILS_BODY_FULL", message.body)
  env
}
