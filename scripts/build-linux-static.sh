#!/usr/bin/env bash
#
# Build a fully static Linux `mails` with musl.
#
# A glibc build records the build machine's symbol versions, so a binary built
# on a new runner refuses to start on an older distribution
# ("GLIBC_2.38 not found"). Linking against musl statically removes the whole
# class of problem: the result runs on any Linux of the same architecture.
#
# Usage:
#   scripts/build-linux-static.sh [output-path]
#
# Environment:
#   MAILS_MUSL_WORKDIR   scratch directory (default: a fresh temp dir)
#
# Requires: musl-tools (Debian/Ubuntu: `apt-get install musl-tools`).

set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
out="${1:-$root/dist/mails-linux-$(uname -m)}"
work="${MAILS_MUSL_WORKDIR:-$(mktemp -d)}"

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
exec musl-gcc \$common "\$@" -static -L$work -lmbfortify
EOF
chmod +x "$work/mails-musl-gcc"
ln -sf "$(command -v ar)" "$work/ar"

# --- build -----------------------------------------------------------------
say "mails: building a static binary (musl, workdir $work)"
cd "$root"
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
