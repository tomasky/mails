#!/bin/sh
# Silence one warning that comes from a dependency's C stub, not from mails.
#
# `moonbitlang/async` ships `thread_pool.c`, which pokes a self-pipe to wake the
# event loop and ignores write(2)'s return value. GCC marks `write` as
# `warn_unused_result`, so every clean native build prints:
#
#   thread_pool.c:470:5: warning: ignoring return value of 'write' declared
#   with attribute 'warn_unused_result' [-Wunused-result]
#
# The compiler flag that would turn it off is not reachable from `moon.pkg`
# (`stub-cc-flags` applies to *our* package's stubs only), so the line is
# patched in place instead. The behaviour is unchanged: a short or failed write
# only means the event loop wakes up spuriously, which it already tolerates.
#
# `moon update` restores `.mooncakes`, after which this script re-applies the
# patch. It is idempotent and exits quietly when the file is absent or already
# patched.
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
file="$root/.mooncakes/moonbitlang/async/src/internal/event_loop/thread_pool.c"

if [ ! -f "$file" ]; then
  exit 0
fi

python3 - "$file" <<'PY'
import sys

path = sys.argv[1]
with open(path, "r", encoding="utf-8") as handle:
    source = handle.read()

patched = source.replace(
    "    write(pool.notify_send, &data, sizeof(data));",
    "    (void)!write(pool.notify_send, &data, sizeof(data));",
)

if patched == source:
    sys.exit(0)

with open(path, "w", encoding="utf-8") as handle:
    handle.write(patched)
print("patched", path)
PY
