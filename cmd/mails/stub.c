/*
 * Exit with an explicit status so a failed command is visible to shell
 * scripts, exactly like the original goimapnotify exit codes.
 */

#include <moonbit.h>
#include <stdlib.h>

MOONBIT_FFI_EXPORT
void mails_exit(int32_t status) {
  exit((int)status);
}
