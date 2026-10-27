///| Running the command attached to a matched rule.

///|
fn trim_output(text : String) -> String {
  trim(text)
}

///|
pub struct ActionOutcome {
  exit_code : Int32
  timed_out : Bool
}

///|
/// Execute one matched rule, logging what ran and how it ended.
pub async fn run_action(
  account : String,
  mailbox : String,
  message : MailMessage,
  hit : RuleMatch,
) -> ActionOutcome {
  let context : ActionContext = {
    account,
    mailbox,
    message,
    rule: hit.rule,
    keywords: hit.keywords,
  }
  let env = action_env(context)
  let timeout = hit.rule.timeout_ms
  log_info(
    "rule '" +
    hit.rule.name +
    "' matched uid " +
    message.uid +
    " in " +
    mailbox +
    " (" +
    hit.keywords.join(", ") +
    ")",
  )
  let (program, args) = if hit.rule.argv.length() > 0 {
    let rendered : Array[String] = []
    for arg in hit.rule.argv {
      rendered.push(render_template(arg, context))
    }
    let program = rendered[0]
    let rest : Array[String] = []
    let mut index = 1
    while index < rendered.length() {
      rest.push(rendered[index])
      index = index + 1
    }
    (program, rest)
  } else {
    ("sh", ["-c", render_template(hit.rule.shell_command, context)])
  }
  let cwd : StringView? = if hit.rule.workdir == "" {
    None
  } else {
    Some(hit.rule.workdir[:])
  }
  let collect = () => {
    @process.collect_output(
      program,
      args,
      extra_env=env,
      inherit_env=true,
      cwd?,
    )
  }
  let result = @async.with_timeout_opt(timeout, () => collect()) catch {
    err => {
      log_warn(
        "rule '" + hit.rule.name + "' failed to start: " + err.to_string(),
      )
      return { exit_code: -1, timed_out: false, }
    }
  }
  match result {
    None => {
      log_warn(
        "rule '" +
        hit.rule.name +
        "' timed out after " +
        format_duration(timeout),
      )
      { exit_code: -1, timed_out: true, }
    }
    Some((exit_code, stdout, stderr)) => {
      let out = trim_output(stdout.text() catch { _ => "" })
      let err = trim_output(stderr.text() catch { _ => "" })
      if out != "" {
        log_debug("rule '" + hit.rule.name + "' stdout: " + out)
      }
      if err != "" {
        log_debug("rule '" + hit.rule.name + "' stderr: " + err)
      }
      if exit_code != 0 {
        let detail = if err != "" {
          ": " + truncate_chars(err, 500)
        } else if out != "" {
          ": " + truncate_chars(out, 500)
        } else {
          ""
        }
        log_warn(
          "rule '" +
          hit.rule.name +
          "' exited with status " +
          exit_code.to_string() +
          detail,
        )
      }
      { exit_code, timed_out: false, }
    }
  }
}
