# `@tomasko/mails`

The npm launcher for [`mails`](https://github.com/tomasky/mails) — watch IMAP
mailboxes with `IDLE`, run a shell command when a message matches subject or body
keywords, and read or send mail from the terminal.

```sh
npm install -g @tomasko/mails

mails init
mails keygen
mails encrypt --account work --write
mails check
mails watch
```

```sh
mails ls                  # newest mail in the mailbox
mails read 42             # one message
mails send --to you@example.com --subject hi --body "hello"
```

`mails` is a single static binary. It keeps `mails.toml` and the encryption key
(`.env`) in the same directory as the binary, so there is no global config
directory to manage.

## Contents

- [Install](#install)
- [What the launcher does](#what-the-launcher-does)
- [Quick start](#quick-start)
- [Where the config lives](#where-the-config-lives)
- [Why there is no `postinstall`](#why-there-is-no-postinstall)
- [The binary cache](#the-binary-cache)
- [Environment variables](#environment-variables)
- [Versions and the release fallback](#versions-and-the-release-fallback)
- [Mirrors, proxies and air-gapped machines](#mirrors-proxies-and-air-gapped-machines)
- [Verifying a download by hand](#verifying-a-download-by-hand)
- [Signals and exit codes](#signals-and-exit-codes)
- [Upgrading and uninstalling](#upgrading-and-uninstalling)
- [Troubleshooting](#troubleshooting)
- [Other ways to install](#other-ways-to-install)
- [Documentation](#documentation)
- [License](#license)

## Install

```sh
npm install -g @tomasko/mails

# the same package, other package managers
pnpm add -g @tomasko/mails
yarn global add @tomasko/mails
bun add -g @tomasko/mails

# run once without installing
npx @tomasko/mails version
```

Requires Node.js 18 or newer. The package installs a `mails` command; the native
binary itself arrives on first use.

This package is a launcher, not the binary. On the first `mails` run it
downloads the prebuilt native binary for your platform from the GitHub release,
verifies its SHA-256 and caches it. Nothing is downloaded at install time.

### Supported platforms

| Platform | Release asset | Notes |
| --- | --- | --- |
| Linux x86-64 | `mails-linux-x86_64` | static, musl — runs on any distribution |
| Linux arm64 | `mails-linux-aarch64` | static, musl |
| macOS Apple silicon | `mails-darwin-aarch64` | arm64 only |

The Linux builds are linked statically against musl, so they run on any
distribution regardless of its glibc version, including Alpine, and in
containers based on `scratch` or `distroless`.

Anything else — Windows, Linux on 32-bit ARM or RISC-V, Intel macOS — has no
published binary. `npm install` succeeds anyway, because npm only checks the
`os`/`cpu` fields; the first run then stops with:

```text
mails: mails does not ship a binary for win32/x64; supported: linux-x86_64,
linux-aarch64 and darwin-aarch64. Build from source instead: …
```

On those platforms build from source (see
[Other ways to install](#other-ways-to-install)) or use
[WSL](https://learn.microsoft.com/windows/wsl/).

## What the launcher does

Every `mails …` invocation goes through `bin/mails.js`, which:

1. Picks the release target for `process.platform` + `process.arch`.
2. Looks for `mails-<version>-<target>` in the [cache](#the-binary-cache) — the
   pinned version first, then any older one left by the fallback described
   [below](#versions-and-the-release-fallback).
3. If nothing usable is cached, downloads the asset and its `.sha256` over
   HTTPS, writes to a temporary file, verifies the digest, `chmod 0755` and
   renames it into place. A failed download never leaves a half-written binary.
4. `exec`s the binary with your arguments, `stdio` inherited, forwarding
   `SIGINT`, `SIGTERM`, `SIGHUP` and `SIGQUIT` so that `Ctrl-C` on
   `mails watch` reaches the watcher rather than killing only the wrapper.

Downloads happen only on the first run of a version; after that the launcher
starts the cached binary directly. Set `MAILS_FORCE_DOWNLOAD=1` to fetch again,
for example after a corrupted file.

Because the launcher is a normal `node` process, `mails watch` shows up in `ps`
as two entries (the wrapper and the binary). Both exit together.

## Quick start

```sh
mails init                       # writes a commented mails.toml, prints its path
$EDITOR ~/.cache/mails/mails.toml   # or the path `mails init` printed

mails keygen                     # writes .env with a fresh MAILS_KEY (mode 0600)
mails encrypt --account work --write   # seals the IMAP password in mails.toml
mails check                      # verifies config, key and every login
mails watch                      # runs in the foreground
```

Then, from another shell:

```sh
mails folders                    # which mailboxes exist
mails ls                         # UID, date, sender, subject of the newest mail
mails ls --unread --json
mails read 42                    # headers and the decoded text body
mails send --to you@example.com --subject "test" --body "hello"
```

`mails` needs an account block per mailbox, plus an `smtp_host` on it if you want
`mails send` to work. The [main README](https://github.com/tomasky/mails#configuration)
documents every key, the placeholder table for rule commands, the IMAP/SMTP host
lists per provider, and the OAuth2 device-flow sign-in that works without a
browser on the server.

## Where the config lives

`mails.toml` and `.env` are resolved **next to the binary**, and with the npm
launcher the binary lives in the user cache:

| Platform | Directory |
| --- | --- |
| Linux | `$XDG_CACHE_HOME/mails` or `~/.cache/mails` |
| macOS | `~/Library/Caches/mails` |

That is fine for trying it out, but a cache clean (`rm -rf ~/.cache/mails`,
`brew cleanup`, some "system cleaner" apps) would take the config, the key and
the OAuth refresh token with it. For a long-lived setup, choose a persistent
path once and export it in your shell profile:

```sh
mkdir -p ~/.config/mails
export MAILS_CONFIG=~/.config/mails/mails.toml
mails init
```

`--config PATH` does the same for a single command. The `.env` file is resolved
next to the config file, so `.env` belongs in `~/.config/mails/` too. Cursor
files (`.<account>.<mailbox>.<digest>.cursor`) and OAuth token files
(`.<account>.oauth`) are written beside it.

Files the binary creates are mode `0600`; `mails encrypt --write` rewrites
`mails.toml` in place, so keep it out of version control as well.

## Why there is no `postinstall`

This package deliberately declares **no install script**. Since npm 12,
dependency lifecycle scripts are blocked unless the user opts in; and pnpm 12
fails a *project* install outright with `ERR_PNPM_IGNORED_BUILDS` when a
dependency declares one.

Downloading lazily from `bin/mails.js` sidesteps all of it: it works under npm,
pnpm, yarn, bun, `npx`, and `--ignore-scripts`, because it is an ordinary
command rather than an install hook. The price is that the first `mails`
invocation needs network access — see
[air-gapped machines](#mirrors-proxies-and-air-gapped-machines) if that is a
problem.

## The binary cache

The downloaded binary is kept outside the package, so reinstalling, upgrading or
clearing `node_modules` never triggers a second download. Cache contents look
like this:

```text
~/.cache/mails/
├── mails-0.2.0-linux-x86_64          # the binary for this machine
└── mails-0.1.8-linux-x86_64          # left over from an older version
```

The version in the file name is the version **of the binary inside**, which is
not always the version the package pins. `mails version` always reports what is
actually running.

To free the space or start clean:

```sh
rm -rf ~/.cache/mails      # macOS: rm -rf ~/Library/Caches/mails
```

The next run downloads again. Note that this deletes the config too, unless you
moved it with `MAILS_CONFIG`.

## Environment variables

These affect the launcher:

| Variable | Effect |
| --- | --- |
| `MAILS_BINARY` | Run this binary and never download anything |
| `MAILS_CACHE_DIR` | Where to keep the downloaded binary |
| `MAILS_VERSION` | Release version to fetch (default: this package's version); setting it also disables the fallback below |
| `MAILS_REPO` | `owner/repo` to download from (default: `tomasky/mails`) |
| `MAILS_RELEASES_BASE` | Host serving the releases, e.g. a GitHub Enterprise or a mirror (default: `https://github.com/<repo>`) |
| `MAILS_DOWNLOAD_BASE` | Full base URL for the binary, overriding `MAILS_REPO`/`MAILS_VERSION` |
| `MAILS_FORCE_DOWNLOAD` | Re-download even if the cached binary exists |
| `MAILS_SKIP_DOWNLOAD` | Never download; fail if the binary is absent |
| `MAILS_NO_VERIFY` | Skip SHA-256 verification of the download |

These affect `mails` itself:

| Variable | Effect |
| --- | --- |
| `MAILS_CONFIG` | Config path when `--config` is not passed |
| `MAILS_KEY` | Encryption key fallback when `.env` does not define it |
| `MAILS_QUIET` | `1` silences everything but errors, including warnings |

Rule commands additionally receive `MAILS_ACCOUNT`, `MAILS_MAILBOX`,
`MAILS_UID`, `MAILS_SUBJECT`, `MAILS_FROM`, `MAILS_TO`, `MAILS_DATE`,
`MAILS_MESSAGE_ID`, `MAILS_RULE`, `MAILS_KEYWORDS`, `MAILS_BODY`,
`MAILS_BODY_FULL` and `MAILS_BODY_TRUNCATED`. See the
[main README](https://github.com/tomasky/mails#environment-variables).

## Versions and the release fallback

The launcher first asks for `v<package version>`. If that tag has not been
published — the usual case for the minutes between an npm publish and the GitHub
release finishing — it asks GitHub for the latest release, says so, and **keeps
the binary under its own version**:

```text
mails: warning: v0.3.0 has not been released; using v0.2.0, which is the latest release
mails: installed ~/.cache/mails/mails-0.2.0-linux-x86_64 (v0.2.0)
```

`mails version` therefore always reports what is actually running, and once
`v0.3.0` is released the launcher downloads it instead of reusing the fallback
binary. Set `MAILS_VERSION` to pin a version and turn the fallback off:

```sh
MAILS_VERSION=0.2.0 mails version    # downloads v0.2.0 or fails
```

Note that the fallback only ever goes *forward* to the latest release as
announced by GitHub; a pinned version that is older than the cache stays pinned.

## Mirrors, proxies and air-gapped machines

`MAILS_DOWNLOAD_BASE`, `MAILS_RELEASES_BASE` and `MAILS_REPO` are there for
forks, private mirrors and air-gapped installs:

```sh
# a mirror that serves mails-linux-x86_64 and mails-linux-x86_64.sha256
export MAILS_DOWNLOAD_BASE=https://internal.example.com/mails
mails version          # downloads from the mirror and caches the result
```

```sh
# a fork, with the version from the package itself
export MAILS_REPO=acme/mails

# GitHub Enterprise: the releases live under /<owner>/<repo>/releases
export MAILS_RELEASES_BASE=https://ghe.example.com/acme/mails
```

The launcher talks to the network with Node's `https` module and does **not**
honour `HTTPS_PROXY`. If outbound access goes through a proxy, do one of:

- put the binary in place yourself:
  `MAILS_CACHE_DIR=/opt/mails-cache` plus the asset copied in as
  `mails-0.2.0-linux-x86_64`, `chmod +x`, and `export MAILS_SKIP_DOWNLOAD=1`;
- or point `MAILS_BINARY` at any `mails` binary you already have:

```sh
export MAILS_BINARY=/usr/local/bin/mails
```

`MAILS_SKIP_DOWNLOAD=1` alone also works once the cache holds a matching binary;
it refuses to reach the network and fails with a clear message when the cache is
empty. In a container image, seed the cache at build time:

```dockerfile
FROM node:22-slim
RUN npm install -g @tomasko/mails \\
 && MAILS_SKIP_DOWNLOAD=1 mails version || true
# or simply copy a binary from the release page and set MAILS_BINARY
```

## Verifying a download by hand

Each asset is published next to a `.sha256` file, and the launcher verifies it
before running the binary. To check an asset yourself:

```sh
curl -L -O https://github.com/tomasky/mails/releases/latest/download/mails-linux-x86_64
curl -L -O https://github.com/tomasky/mails/releases/latest/download/mails-linux-x86_64.sha256
sha256sum -c mails-linux-x86_64.sha256
chmod +x mails-linux-x86_64
./mails-linux-x86_64 version
```

A missing `.sha256` is a warning rather than a failure, so older releases keep
working; a mismatching digest deletes the download and stops with both digests
printed. `MAILS_NO_VERIFY=1` skips the check — only do that behind a mirror you
control.

## Signals and exit codes

The launcher is transparent:

- arguments are passed through unchanged, so `mails --config … watch` behaves
  exactly as with the binary alone;
- `stdout` and `stderr` are inherited, so logs stream into your terminal,
  `journalctl` or Docker;
- `stdin` is inherited too, which is what `mails send` uses to read a body from a
  pipe;
- `SIGINT`, `SIGTERM`, `SIGHUP` and `SIGQUIT` are forwarded to the binary;
- the wrapper exits with the binary's status, or dies from the same signal, so a
  supervisor sees the real outcome.

One consequence: `Ctrl-C` reaches both processes, and the wrapper waits for the
binary to finish logging before it exits. Give `mails watch` a stop timeout of a
few seconds in systemd (`TimeoutStopSec=10`) rather than killing it instantly.

## Upgrading and uninstalling

```sh
npm install -g @tomasko/mails@latest     # upgrade the launcher
mails version                            # fetch and report the new binary
npm uninstall -g @tomasko/mails          # remove the launcher
rm -rf ~/.cache/mails                    # remove the binary and cache
```

Upgrading the package does not by itself delete the previous binary in the
cache; it is a few megabytes per version and can be removed by hand. Old
binaries are also what the fallback uses when a newer package is installed
before its release exists.

If you moved the config with `MAILS_CONFIG`, remove that directory separately —
it holds the key and the OAuth refresh tokens.

## Troubleshooting

| Symptom | Cause and fix |
| --- | --- |
| `mails: could not download the mails binary for …` with a list of URLs | no network, no DNS, or a blocked `github.com`. Use a mirror via `MAILS_DOWNLOAD_BASE`, or set `MAILS_BINARY` |
| `mails: VERSION has not been released; using V…` | harmless: the GitHub release for the pinned version does not exist yet, the previous one was downloaded instead |
| `checksum mismatch for mails-linux-x86_64` | a proxy, a mirror or a partial download corrupted the file; retry, then `rm` the file in the cache and run again |
| `mails: no checksum published for …` | an old release without a `.sha256` asset; the binary is used unverified |
| `EACCES: permission denied` on the cache path | `MAILS_CACHE_DIR` points somewhere not writable; pick a directory you own |
| `mails: MAILS_BINARY points at …, which does not exist` | fix the path or unset the variable |
| `MAILS_SKIP_DOWNLOAD is set but no mails binary is installed in …` | seed the cache first (see above) |
| `mails does not ship a binary for darwin/x64` | Intel macOS is unsupported; build from source |
| First command after `npm install` hangs for a minute | it is downloading ~10 MB; later runs read the cache and start instantly |
| `mails watch` exits immediately with status 1 | run `mails check` first: it prints the config path, the key status and each login failure |
| Two `mails` processes in `ps` | expected: the Node wrapper and the native binary |

## Other ways to install

The npm launcher is one of several options; they all install the same command.

```sh
# Installer script (no Node.js required, verifies SHA-256)
curl -LsSf https://raw.githubusercontent.com/tomasky/mails/master/install.sh | bash

# From the MoonBit package registry (requires the MoonBit toolchain)
moon install kupas/mails/cmd/mails

# Prebuilt binary from a release
curl -L -o mails https://github.com/tomasky/mails/releases/latest/download/mails-linux-x86_64
chmod +x mails

# Build from source
git clone https://github.com/tomasky/mails && cd mails
moon build --target native --release
# then copy _build/native/release/build/cmd/mails/mails.exe to your PATH
```

The installer script and the MoonBit route put the binary in a stable directory
(`~/.local/bin` and `~/.moon/bin` by default), so the default next-to-the-binary
config is persistent and the `MAILS_CONFIG` workaround above is unnecessary.

## Documentation

The [main README](https://github.com/tomasky/mails#readme) covers the TOML
configuration, keyword rules, placeholders, password encryption, the IMAP and
SMTP host tables, OAuth2 device-flow sign-in, and how watching works. In short:

```text
watch       follow mailboxes with IMAP IDLE
sync        process existing matching mail once, then exit
check       verify config, key, logins and mailbox counts
ls          list the newest messages of a mailbox
read        print one message
folders     list the mailboxes on the server
send        send a message over SMTP
encrypt     seal an account password with the key in .env
keygen      create or rotate the encryption key in .env
rules       list configured rules
env         show .env with secret values masked
init        write a commented mails.toml next to the binary
version     print the version
```

`mails check` is the quickest way to validate a setup.

## Package contents

| File | Purpose |
| --- | --- |
| `bin/mails.js` | the `mails` command: resolve, download, forward stdio and signals |
| `lib.js` | target detection, cache layout, HTTPS download, SHA-256 verification |
| `README.md` | this file |

Nothing is executed at install time, and the package has no dependencies.

## License

Apache-2.0
