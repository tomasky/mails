/*
 * Wall clock for outgoing mail: the `Date:` header and the `Message-ID`.
 *
 * MoonBit's standard library has no clock, and shelling out to `date` would add
 * a process per message, so this is the smallest possible C dependency. It uses
 * `time(NULL)`, which is UTC seconds on every platform mails supports.
 */

#include <moonbit.h>
#include <time.h>

MOONBIT_FFI_EXPORT
int64_t mails_unix_time(void) {
  return (int64_t)time(NULL);
}
