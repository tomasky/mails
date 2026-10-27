#!/usr/bin/env bash
#
# Build a fully static Linux `mails` with musl.
#
# A glibc build records the build machine's symbol versions, so a binary built
# on a new runner refuses to start on an older distribution
# ("GLIBC_2.38 not found"). Linking against musl statically removes the whole
# class of problem: the result runs on any Linux of the same architecture.
#
# TLS: moonbitlang/async loads OpenSSL with dlopen(3), which cannot work in a
# statically linked program ("Dynamic loading not supported"), so a static
# build used to fail every TLS connection with `TlsError("failed to load
# OpenSSL")`. To keep TLS working we link OpenSSL statically and compile
# async's TLS stub from scripts/tls/openssl_static.c, a copy of the upstream
# `openssl.c` whose only difference is that it references the OpenSSL symbols
# directly instead of resolving them with dlsym.
#
# Usage:
#   scripts/build-linux-static.sh [output-path]
#
# Environment:
#   MAILS_MUSL_WORKDIR     scratch directory (default: a fresh temp dir)
#   MAILS_OPENSSL_SRC      OpenSSL source tree to build the static libs from
#                          (default: download and build one in the workdir)
#   MAILS_OPENSSL_VERSION  OpenSSL version to download (default: 3.5.5)
#   MAILS_OPENSSL_TARGET   OpenSSL Configure target (default: derived from
#                          `uname -m`, e.g. linux-x86_64 or linux-aarch64)
#   MAILS_OPENSSL_MUSL     install prefix of a prebuilt musl static OpenSSL
#                          (skips building it; must contain include/ and lib/)
#   MAILS_NO_TLS           set to 1 to build without TLS support
#
# Requires: musl-tools (Debian/Ubuntu: `apt-get install musl-tools`), plus
# perl and make when OpenSSL has to be built.

set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
out="${1:-$root/dist/mails-linux-$(uname -m)}"
work="${MAILS_MUSL_WORKDIR:-$(mktemp -d)}"
openssl_version="${MAILS_OPENSSL_VERSION:-3.5.5}"
use_tls="${MAILS_NO_TLS:+0}"
use_tls="${use_tls:-1}"

# OpenSSL's Configure target must match the machine we are building on: the
# release matrix builds on both x86_64 and aarch64 runners, and a hardcoded
# `linux-x86_64` emits `-m64`, which the aarch64 compiler rejects with
# "unrecognized command-line option '-m64'".
if [ -z "${MAILS_OPENSSL_TARGET:-}" ]; then
  case "$(uname -m)" in
  x86_64 | amd64) MAILS_OPENSSL_TARGET=linux-x86_64 ;;
  aarch64 | arm64) MAILS_OPENSSL_TARGET=linux-aarch64 ;;
  *) MAILS_OPENSSL_TARGET=linux-generic64 ;;
  esac
fi
openssl_target="$MAILS_OPENSSL_TARGET"

say() { printf '%s\n' "$*"; }
die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

command -v musl-gcc >/dev/null 2>&1 ||
  die "musl-gcc not found; install musl-tools (apt-get install musl-tools)"

# The kernel UAPI headers (linux/*.h, asm/*.h) live in /usr/include, which is
# not on musl-gcc's default search path. Find the multiarch directory too:
# linux/types.h includes <asm/types.h>.
multiarch=""
for dir in /usr/include/*-linux-gnu; do
  if [ -d "$dir" ]; then
    multiarch="$dir"
    break
  fi
done
[ -n "$multiarch" ] || die "no /usr/include/*-linux-gnu directory found"

mkdir -p "$work"

# --- static OpenSSL --------------------------------------------------------
# Produces $openssl_prefix with lib/libssl.a, lib/libcrypto.a and include/.
# The archives must be built with musl: the distro's libssl.a/libcrypto.a are
# glibc objects, and mixing them into a musl binary drags in glibc-only
# runtime dependencies (zlib, zstd, dlopen) that defeat the point.
openssl_prefix="${MAILS_OPENSSL_MUSL:-$work/openssl-musl}"

build_openssl() {
  local src="$1"
  say "mails: building static OpenSSL $openssl_version for $openssl_target (musl)"
  (
    cd "$src"
    make clean >/dev/null 2>&1 || true
    # no-zlib/no-zstd keeps libcrypto.a free of external compression deps;
    # no-shared/no-dso remove the dynamic-loading code paths entirely.
    # --openssldir must be a path that exists on the *user's* machine: it is
    # baked into libcrypto as OPENSSLDIR and drives the default CA lookup
    # (/etc/ssl/certs, /etc/ssl/cert.pem). The build workdir would leave the
    # trust store empty and every handshake would fail verification.
    CC=musl-gcc \
      CFLAGS="-idirafter /usr/include -idirafter $multiarch" \
      ./Configure "$openssl_target" -static \
        --prefix="$openssl_prefix" \
        --openssldir=/etc/ssl \
        no-shared no-dso no-tests no-zlib no-zstd no-asm no-async
    # build_libs only builds libcrypto.a/libssl.a. `build_sw` would also
    # compile the whole `openssl` command-line suite, which adds minutes to
    # every release build and produces nothing `mails` links.
    make -j"$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)" build_libs
    # Copy the two archives and the headers instead of `make install`, which
    # also spends minutes generating man pages we never read.
    mkdir -p "$openssl_prefix/lib" "$openssl_prefix/include"
    cp libssl.a libcrypto.a "$openssl_prefix/lib/"
    cp -R include/openssl "$openssl_prefix/include/"
  )
}

if [ "$use_tls" = 1 ]; then
  if [ -n "${MAILS_OPENSSL_MUSL:-}" ]; then
    [ -f "$openssl_prefix/lib/libssl.a" ] &&
      [ -f "$openssl_prefix/lib/libcrypto.a" ] ||
      die "MAILS_OPENSSL_MUSL=$openssl_prefix has no lib/libssl.a + lib/libcrypto.a"
  elif [ -n "${MAILS_OPENSSL_SRC:-}" ]; then
    build_openssl "$MAILS_OPENSSL_SRC"
  else
    command -v perl >/dev/null 2>&1 || die "perl is required to configure OpenSSL"
    src="$work/openssl-$openssl_version"
    if [ ! -d "$src" ]; then
      tarball="$work/openssl-$openssl_version.tar.gz"
      say "mails: downloading OpenSSL $openssl_version"
      curl -fsSL -o "$tarball" \
        "https://github.com/openssl/openssl/releases/download/openssl-$openssl_version/openssl-$openssl_version.tar.gz" ||
        die "cannot download OpenSSL $openssl_version"
      tar -xzf "$tarball" -C "$work"
    fi
    build_openssl "$src"
  fi
fi

# --- fortify shim ----------------------------------------------------------
# The MoonBit runtime is compiled against glibc headers and references the
# __*_chk fortify symbols. musl has no fortify, so supply them.
cat >"$work/fortify_shim.c" <<'EOF'
#include <string.h>
#include <stdarg.h>
#include <stdio.h>
void *__memcpy_chk(void *d, const void *s, size_t n, size_t dn) { (void)dn; return memcpy(d, s, n); }
void *__memmove_chk(void *d, const void *s, size_t n, size_t dn) { (void)dn; return memmove(d, s, n); }
void *__memset_chk(void *d, int c, size_t n, size_t dn) { (void)dn; return memset(d, c, n); }
char *__strcpy_chk(char *d, const char *s, size_t dn) { (void)dn; return strcpy(d, s); }
char *__stpcpy_chk(char *d, const char *s, size_t dn) { (void)dn; return stpcpy(d, s); }
char *__strcat_chk(char *d, const char *s, size_t dn) { (void)dn; return strcat(d, s); }
char *__strncpy_chk(char *d, const char *s, size_t n, size_t dn) { (void)dn; return strncpy(d, s, n); }
char *__strncat_chk(char *d, const char *s, size_t n, size_t dn) { (void)dn; return strncat(d, s, n); }
int __sprintf_chk(char *s, int flag, size_t slen, const char *fmt, ...) { (void)flag; (void)slen; va_list ap; va_start(ap, fmt); int r = vsprintf(s, fmt, ap); va_end(ap); return r; }
int __vsprintf_chk(char *s, int flag, size_t slen, const char *fmt, va_list ap) { (void)flag; (void)slen; return vsprintf(s, fmt, ap); }
int __snprintf_chk(char *s, size_t n, int flag, size_t slen, const char *fmt, ...) { (void)flag; (void)slen; va_list ap; va_start(ap, fmt); int r = vsnprintf(s, n, fmt, ap); va_end(ap); return r; }
int __vsnprintf_chk(char *s, size_t n, int flag, size_t slen, const char *fmt, va_list ap) { (void)flag; (void)slen; return vsnprintf(s, n, fmt, ap); }
int __printf_chk(int flag, const char *fmt, ...) { (void)flag; va_list ap; va_start(ap, fmt); int r = vprintf(fmt, ap); va_end(ap); return r; }
int __vprintf_chk(int flag, const char *fmt, va_list ap) { (void)flag; return vprintf(fmt, ap); }
int __fprintf_chk(FILE *f, int flag, const char *fmt, ...) { (void)flag; va_list ap; va_start(ap, fmt); int r = vfprintf(f, fmt, ap); va_end(ap); return r; }
int __vfprintf_chk(FILE *f, int flag, const char *fmt, va_list ap) { (void)flag; return vfprintf(f, fmt, ap); }
EOF
musl-gcc -O2 -c "$work/fortify_shim.c" -o "$work/fortify_shim.o"
ar rcs "$work/libmbfortify.a" "$work/fortify_shim.o"

# --- compiler driver -------------------------------------------------------
tls_flags=""
if [ "$use_tls" = 1 ]; then
  tls_flags="-L$openssl_prefix/lib -lssl -lcrypto -ldl -lpthread"
fi
cat >"$work/mails-musl-gcc" <<EOF
#!/bin/sh
# -idirafter keeps musl's libc headers ahead of glibc's while still making the
# kernel UAPI headers reachable; -include limits.h supplies NAME_MAX, which
# glibc's <unistd.h> provides transitively and musl's does not.
common="-idirafter /usr/include -idirafter $multiarch -include limits.h"
for arg in "\$@"; do
  if [ "\$arg" = "-c" ]; then
    # shellcheck disable=SC2086
    exec musl-gcc \$common "\$@"
  fi
done
# shellcheck disable=SC2086
exec musl-gcc \$common "\$@" -static -L$work -lmbfortify $tls_flags
EOF
chmod +x "$work/mails-musl-gcc"
ln -sf "$(command -v ar)" "$work/ar"

# --- TLS stub --------------------------------------------------------------
# Swap async's dlopen-based loader for the directly-linked one. The dependency
# lives under .mooncakes (gitignored, regenerated by `moon`), so the swap is
# restored on exit and never becomes part of the source tree.
async_tls_dir="$root/.mooncakes/moonbitlang/async/src/tls"
restore_tls_stub() {
  if [ -f "$async_tls_dir/openssl.c.mails-orig" ]; then
    mv -f "$async_tls_dir/openssl.c.mails-orig" "$async_tls_dir/openssl.c"
  fi
}

# `moon update` only refreshes the registry index; the package sources land in
# .mooncakes when a build/check first resolves them. A fresh CI runner has an
# empty .mooncakes, so make sure async is unpacked before patching its stub.
ensure_moon_deps() {
  [ -d "$async_tls_dir" ] && return 0
  say "mails: resolving dependencies (moon update && moon check)"
  ( cd "$root" && moon update ) >/dev/null 2>&1 || true
  ( cd "$root" && moon check --target native ) >/dev/null 2>&1 || true
  if [ ! -d "$async_tls_dir" ]; then
    say "mails: fetching dependencies with a native build"
    ( cd "$root" && moon build --target native ) >/dev/null 2>&1 || true
  fi
}

if [ "$use_tls" = 1 ]; then
  ensure_moon_deps
  [ -d "$async_tls_dir" ] ||
    die "$async_tls_dir is still missing after `moon update && moon check`"
  cp "$async_tls_dir/openssl.c" "$async_tls_dir/openssl.c.mails-orig"
  cp "$root/scripts/tls/openssl_static.c" "$async_tls_dir/openssl.c"
  trap restore_tls_stub EXIT
fi

# --- build -----------------------------------------------------------------
say "mails: building a static binary (musl, workdir $work)"
cd "$root"
# Drop any native objects from an earlier run with a different compiler: the
# dependency bootstrap above, or a previous glibc build, would otherwise leave
# objects that must not be reused for a musl static link.
rm -rf "$root/_build/native"
MOON_CC="$work/mails-musl-gcc" MOON_AR=ar \
  moon build --target native --release

bin="$root/_build/native/release/build/cmd/mails/mails.exe"
[ -f "$bin" ] || die "build did not produce $bin"

mkdir -p "$(dirname "$out")"
cp "$bin" "$out"
chmod 755 "$out"

# --- verify ----------------------------------------------------------------
say "mails: wrote $out"
file "$out" || true
if ! file "$out" | grep -q "statically linked"; then
  die "$out is not statically linked"
fi
if ldd "$out" >/dev/null 2>&1; then
  die "$out is a dynamic executable"
fi
say "mails: verified statically linked"

# A static binary must carry its TLS stack; confirm OpenSSL really was linked
# in rather than silently dropped. Capture the symbol table first: piping nm
# into `grep -q` would make grep exit early, SIGPIPE kill nm, and `pipefail`
# turn a successful match into a failure.
if [ "$use_tls" = 1 ]; then
  if command -v nm >/dev/null 2>&1; then
    symbols="$(nm "$out" 2>/dev/null || true)"
    case "$symbols" in
    *" T SSL_connect"*) ;;
    *) die "$out has no static OpenSSL symbols (TLS would fail at runtime)" ;;
    esac
  fi
  say "mails: verified static TLS (OpenSSL $openssl_version)"
else
  say "mails: built without TLS (MAILS_NO_TLS=1)"
fi
