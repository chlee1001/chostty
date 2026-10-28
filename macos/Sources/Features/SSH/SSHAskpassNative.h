#ifndef SSH_ASKPASS_NATIVE_H
#define SSH_ASKPASS_NATIVE_H

#include <stddef.h>
#include <sys/types.h>

int ssh_askpass_native_install_signal_handlers(void);
int ssh_askpass_native_cancelled(void);
int ssh_askpass_native_commit_output(void);
void ssh_askpass_native_exit_success(void) __attribute__((noreturn));
int ssh_askpass_native_read_answer(
    const char *prompt,
    char *buffer,
    size_t capacity,
    size_t *out_length,
    pid_t parent_pid,
    int echo
);
int ssh_askpass_native_wait_for_parent_exit(pid_t parent_pid, int timeout_milliseconds);
int ssh_askpass_native_install_fatal_handlers(pid_t parent_pid);
void ssh_askpass_native_restore_fatal_handlers(void);
void ssh_askpass_native_wipe(void *buffer, size_t length);

#endif
