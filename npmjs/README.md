# `@tomasko/mails`

The npm launcher for [`mails`](https://github.com/tomasky/mails) — watch IMAP
mailboxes with `IDLE` and run shell commands when a message matches subject or
body keywords.

```sh
npm install -g @tomasko/mails

mails init
mails keygen
mails encrypt --account work --write
mails check
mails watch
```

`mails` is a single static binary. It keeps `mails.toml` and the encryption key
(`.env`) in the same directory as the binary, so there is no global config
directory to manage.

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

This package is a launcher, not the binary itself. On the first `mails` run it
downloads the prebuilt native binary for your platform from the GitHub release,
verifies its SHA-256 and caches it. Nothing is downloaded at install time.

## What gets downloaded

| Platform | Release asset |
| --- | --- |
| Linux x86-64 | `mails-linux-x86_64` (static, musl) |
| Linux arm64 | `mails-linux-aarch64` (static, musl) |
| macOS Apple silicon | `mails-darwin-aarch64` |

The Linux builds are linked statically against musl, so they run on any
distribution regardless of its glibc version.

## Why there is no `postinstall`

This package deliberately declares **no install script**. Since npm 12,
dependency lifecycle scripts are blocked unless the user opts in; and pnpm 12
fails a *project* install outright with `ERR_PNPM_IGNORED_BUILDS` when a
dependency declares one.

Downloading lazily from `bin/mails.js` sidesteps all of it: it works under npm,
pnpm, yarn, bun, `npx`, and `--ignore-scripts`, because it is an ordinary
command rather than an install hook.

## Cache location

The downloaded binary is kept outside the package, so reinstalling or clearing
`node_modules` never triggers a second download:

| Platform | Path |
| --- | --- |
| Linux | `$XDG_CACHE_HOME/mails` or `~/.cache/mails` |
| macOS | `~/Library/Caches/mails` |

Because the config lives next to the binary, `mails init` writes `mails.toml`
into the cache directory by default. That is fine for trying it out, but a
cache clean would remove the config and the `.env` key with it. For a
long-lived setup, point `MAILS_CONFIG` at a persistent directory first:

```sh
mkdir -p ~/.config/mails
export MAILS_CONFIG=~/.config/mails/mails.toml
mails init
```

Put that `export` in your shell profile, or pass `--config` on every command.
The `.env` file is resolved next to the config file.

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

Rule commands additionally receive `MAILS_ACCOUNT`, `MAILS_SUBJECT`,
`MAILS_FROM`, `MAILS_BODY` and friends. See the
[main README](https://github.com/tomasky/mails#environment-variables).

### When the pinned release does not exist yet

The launcher first asks for `v<package version>`. If that tag has not been
published — the usual case when the npm package is bumped before the GitHub
release — it falls back to the latest release, says so, and **keeps the binary
under its own version**:

```
mails: warning: v0.2.0 has not been released; using v0.1.7, which is the latest release
mails: installed ~/.cache/mails/mails-0.1.7-linux-x86_64 (v0.1.7)
```

`mails version` therefore always reports what is actually running, and once
v0.2.0 is released the launcher picks it up instead of reusing the older
binary. Set `MAILS_VERSION` to pin a version and turn the fallback off.

`MAILS_DOWNLOAD_BASE`, `MAILS_RELEASES_BASE` and `MAILS_REPO` are there for
forks, private mirrors and air-gapped installs:

```sh
export MAILS_DOWNLOAD_BASE=https://internal.example.com/mails
mails version          # downloads from the mirror and caches the result
```

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

Every release asset is published with a `.sha256` file:

```sh
curl -L -O https://github.com/tomasky/mails/releases/latest/download/mails-linux-x86_64.sha256
sha256sum -c mails-linux-x86_64.sha256
```

## Documentation

The [main README](https://github.com/tomasky/mails#readme) covers the TOML
configuration, keyword rules, placeholders, password encryption and how
watching works. `mails check` is the quickest way to validate a setup.

## License

Apache-2.0
