#define __STDC_WANT_LIB_EXT1__ 1
#include "SSHAskpassNative.h"

#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdint.h>
#include <string.h>
#include <sys/event.h>
#include <sys/time.h>
#include <termios.h>
#include <time.h>
#include <unistd.h>

_Static_assert(ATOMIC_INT_LOCK_FREE == 2, "ASKPASS flags must be lock-free");

static atomic_int cancelled = ATOMIC_VAR_INIT(0);
static atomic_int reader_finished = ATOMIC_VAR_INIT(0);
static pid_t fatal_parent;
static stack_t fatal_stack;
static unsigned char fatal_stack_storage[SIGSTKSZ];
static unsigned char watcher_stack_storage[SIGSTKSZ];
static struct sigaction saved_fatal_actions[7];
static const int fatal_signals[7] = { SIGSEGV, SIGBUS, SIGILL, SIGTRAP, SIGABRT, SIGFPE, SIGSYS };

static void cancellation_handler(int signal_number) {
    (void)signal_number;
    atomic_store_explicit(&cancelled, 1, memory_order_relaxed);
}

static void fatal_handler(int signal_number) {
    if (fatal_parent > 1 && getppid() == fatal_parent) {
        (void)kill(fatal_parent, SIGKILL);
    }
    (void)signal(signal_number, SIG_DFL);
    (void)kill(getpid(), signal_number);
}

static int set_close_on_exec(int descriptor) {
    int flags = fcntl(descriptor, F_GETFD);
    return flags >= 0 && fcntl(descriptor, F_SETFD, flags | FD_CLOEXEC) == 0;
}

static int deadline_reached(const struct timespec *deadline) {
    struct timespec now;
    if (clock_gettime(CLOCK_MONOTONIC, &now) != 0) return 1;
    return now.tv_sec > deadline->tv_sec ||
        (now.tv_sec == deadline->tv_sec && now.tv_nsec >= deadline->tv_nsec);
}

static void short_pause(void) {
    const struct timespec pause = { .tv_sec = 0, .tv_nsec = 10000000L };
    while (nanosleep(&pause, NULL) != 0 && errno == EINTR) {}
}

int ssh_askpass_native_install_signal_handlers(void) {
    struct sigaction action;
    memset(&action, 0, sizeof(action));
    action.sa_handler = cancellation_handler;
    sigemptyset(&action.sa_mask);
    action.sa_flags = 0;
    const int signals[] = { SIGINT, SIGTERM, SIGHUP, SIGQUIT };
    for (size_t i = 0; i < sizeof(signals) / sizeof(signals[0]); i++) {
        if (sigaction(signals[i], &action, NULL) != 0) return -1;
    }
    if (signal(SIGPIPE, SIG_IGN) == SIG_ERR) return -1;
    return 0;
}

int ssh_askpass_native_cancelled(void) {
    return atomic_load_explicit(&cancelled, memory_order_relaxed) != 0;
}

int ssh_askpass_native_commit_output(void) {
    sigset_t signals;
    sigemptyset(&signals);
    sigaddset(&signals, SIGINT);
    sigaddset(&signals, SIGTERM);
    sigaddset(&signals, SIGHUP);
    sigaddset(&signals, SIGQUIT);
    if (pthread_sigmask(SIG_BLOCK, &signals, NULL) != 0) return 0;
    sigset_t pending;
    if (sigpending(&pending) != 0) return 0;
    return !ssh_askpass_native_cancelled() && !sigismember(&pending, SIGINT) &&
        !sigismember(&pending, SIGTERM) && !sigismember(&pending, SIGHUP) &&
        !sigismember(&pending, SIGQUIT);
}

void ssh_askpass_native_exit_success(void) {
    _exit(0);
}

struct read_watcher {
    pid_t parent_pid;
    pthread_t reader;
    pthread_mutex_t mutex;
    pthread_cond_t condition;
    int ready;
    int failed;
};

static void watcher_finish_setup(struct read_watcher *watcher, int failed) {
    (void)pthread_mutex_lock(&watcher->mutex);
    watcher->failed = failed;
    watcher->ready = 1;
    (void)pthread_cond_signal(&watcher->condition);
    (void)pthread_mutex_unlock(&watcher->mutex);
}

static void *watch_parent_while_reading(void *context) {
    struct read_watcher *watcher = context;
    sigset_t cancellation_signals;
    sigemptyset(&cancellation_signals);
    sigaddset(&cancellation_signals, SIGINT);
    sigaddset(&cancellation_signals, SIGTERM);
    sigaddset(&cancellation_signals, SIGHUP);
    sigaddset(&cancellation_signals, SIGQUIT);
    stack_t watcher_stack = {
        .ss_sp = watcher_stack_storage,
        .ss_size = sizeof(watcher_stack_storage),
        .ss_flags = 0,
    };
    if (pthread_sigmask(SIG_BLOCK, &cancellation_signals, NULL) != 0 ||
        sigaltstack(&watcher_stack, NULL) != 0) {
        watcher_finish_setup(watcher, 1);
        return NULL;
    }

    int queue = kqueue();
    if (queue < 0 || !set_close_on_exec(queue)) {
        if (queue >= 0) (void)close(queue);
        watcher_finish_setup(watcher, 1);
        return NULL;
    }
    struct kevent change;
    EV_SET(&change, (uintptr_t)watcher->parent_pid, EVFILT_PROC, EV_ADD | EV_ENABLE, NOTE_EXIT, 0, NULL);
    if (kevent(queue, &change, 1, NULL, 0, NULL) != 0) {
        (void)close(queue);
        watcher_finish_setup(watcher, 1);
        return NULL;
    }
    watcher_finish_setup(watcher, 0);

    int parent_exited = 0;
    while (!atomic_load_explicit(&reader_finished, memory_order_acquire)) {
        struct kevent event;
        const struct timespec timeout = { .tv_sec = 0, .tv_nsec = 20000000L };
        int count = kevent(queue, NULL, 0, &event, 1, &timeout);
        if (count < 0 && errno == EINTR) continue;
        if (count > 0 || getppid() != watcher->parent_pid) parent_exited = 1;
        if (parent_exited) {
            atomic_store_explicit(&cancelled, 1, memory_order_release);
            (void)pthread_kill(watcher->reader, SIGTERM);
        }
    }
    (void)close(queue);
    return NULL;
}

static int wait_for_watcher(struct read_watcher *watcher) {
    if (pthread_mutex_lock(&watcher->mutex) != 0) return -1;
    while (!watcher->ready) {
        if (pthread_cond_wait(&watcher->condition, &watcher->mutex) != 0) {
            (void)pthread_mutex_unlock(&watcher->mutex);
            return -1;
        }
    }
    int failed = watcher->failed;
    (void)pthread_mutex_unlock(&watcher->mutex);
    return failed ? -1 : 0;
}

static int write_tty(int descriptor, const char *bytes, size_t length) {
    size_t offset = 0;
    while (offset < length) {
        if (ssh_askpass_native_cancelled()) return -1;
        ssize_t written = write(descriptor, bytes + offset, length - offset);
        if (written > 0) {
            offset += (size_t)written;
            continue;
        }
        if (written < 0 && errno == EINTR) continue;
        return -1;
    }
    return 0;
}

static int is_enabled_control(cc_t value) {
    return value != _POSIX_VDISABLE;
}

static size_t erase_last_character(char *buffer, size_t count) {
    if (count == 0) return 0;

    size_t start = count - 1;
    while (start > 0 && ((unsigned char)buffer[start] & 0xc0) == 0x80) start--;
    unsigned char lead = (unsigned char)buffer[start];
    size_t expected = lead < 0x80 ? 1 :
        (lead >= 0xc2 && lead <= 0xdf) ? 2 :
        (lead >= 0xe0 && lead <= 0xef) ? 3 :
        (lead >= 0xf0 && lead <= 0xf4) ? 4 : 0;
    if (expected == 0 || count - start != expected) start = count - 1;
    ssh_askpass_native_wipe(buffer + start, count - start);
    return start;
}

static void destroy_watcher(struct read_watcher *watcher) {
    (void)pthread_cond_destroy(&watcher->condition);
    (void)pthread_mutex_destroy(&watcher->mutex);
}

/* readpassphrase cannot distinguish a returned prefix from EOF or embedded NUL. */
int ssh_askpass_native_read_answer(
    const char *prompt,
    char *buffer,
    size_t capacity,
    size_t *out_length,
    pid_t parent_pid,
    int echo
) {
    if (prompt == NULL || buffer == NULL || out_length == NULL || capacity < 2 || parent_pid <= 1) {
        errno = EINVAL;
        return -1;
    }
    *out_length = 0;
    ssh_askpass_native_wipe(buffer, capacity);
    atomic_store_explicit(&reader_finished, 0, memory_order_release);

    struct read_watcher watcher = {
        .parent_pid = parent_pid,
        .reader = pthread_self(),
        .mutex = PTHREAD_MUTEX_INITIALIZER,
        .condition = PTHREAD_COND_INITIALIZER,
        .ready = 0,
        .failed = 0,
    };
    pthread_t watcher_thread;
    int watcher_started = pthread_create(&watcher_thread, NULL, watch_parent_while_reading, &watcher) == 0;
    int watcher_ready = watcher_started ? wait_for_watcher(&watcher) : -1;
    if (watcher_ready != 0) {
        atomic_store_explicit(&reader_finished, 1, memory_order_release);
        if (watcher_started) (void)pthread_join(watcher_thread, NULL);
        destroy_watcher(&watcher);
        return -1;
    }

    int descriptor = open("/dev/tty", O_RDWR | O_NOCTTY | O_CLOEXEC);
    struct termios saved;
    int changed_terminal = 0;
    int result = -1;
    if (descriptor >= 0 && isatty(descriptor) == 1 && tcgetattr(descriptor, &saved) == 0 &&
        !ssh_askpass_native_cancelled()) {
        struct termios current = saved;
        current.c_lflag &= ~(ICANON | ECHONL);
        current.c_lflag |= ISIG;
        current.c_cc[VSUSP] = _POSIX_VDISABLE;
        current.c_cc[VDSUSP] = _POSIX_VDISABLE;
        if (echo) current.c_lflag |= ECHO;
        else current.c_lflag &= ~ECHO;
        current.c_cc[VMIN] = 1;
        current.c_cc[VTIME] = 0;
        if (tcsetattr(descriptor, TCSAFLUSH, &current) == 0) {
            changed_terminal = 1;
            if (write_tty(descriptor, prompt, strlen(prompt)) == 0) {
                size_t count = 0;
                int invalid = 0;
                int terminated = 0;
                while (!ssh_askpass_native_cancelled() && !terminated) {
                    unsigned char character;
                    ssize_t read_count = read(descriptor, &character, 1);
                    if (read_count == 1) {
                        if (character == '\r' || character == '\n') {
                            terminated = 1;
                        } else if (is_enabled_control(saved.c_cc[VEOF]) && character == saved.c_cc[VEOF]) {
                            invalid = 1;
                            terminated = 1;
                        } else if (
                            (is_enabled_control(saved.c_cc[VSUSP]) && character == saved.c_cc[VSUSP]) ||
                            (is_enabled_control(saved.c_cc[VDSUSP]) && character == saved.c_cc[VDSUSP])
                        ) {
                            invalid = 1;
                        } else if (!invalid && is_enabled_control(saved.c_cc[VERASE]) &&
                            character == saved.c_cc[VERASE]) {
                            count = erase_last_character(buffer, count);
                        } else if (!invalid && is_enabled_control(saved.c_cc[VKILL]) &&
                            character == saved.c_cc[VKILL]) {
                            ssh_askpass_native_wipe(buffer, count);
                            count = 0;
                        } else if (!invalid && character == '\0') {
                            invalid = 1;
                        } else if (!invalid && count >= capacity - 2) {
                            invalid = 1;
                        } else if (!invalid) {
                            buffer[count++] = (char)character;
                        }
                        (void)memset_s(&character, sizeof(character), 0, sizeof(character));
                    } else if (read_count == 0) {
                        invalid = 1;
                        break;
                    } else if (errno != EINTR) {
                        invalid = 1;
                        break;
                    }
                }
                if (!echo) (void)write_tty(descriptor, "\n", 1);
                if (terminated && !invalid && count > 0 && count <= capacity - 2 &&
                    !ssh_askpass_native_cancelled()) {
                    buffer[count] = '\0';
                    *out_length = count;
                    result = 0;
                }
            }
        }
    }
    if (changed_terminal) {
        int restored;
        do {
            restored = tcsetattr(descriptor, TCSAFLUSH, &saved);
        } while (restored != 0 && errno == EINTR);
        if (restored != 0) result = -1;
    }
    if (descriptor >= 0) (void)close(descriptor);
    atomic_store_explicit(&reader_finished, 1, memory_order_release);
    (void)pthread_join(watcher_thread, NULL);
    destroy_watcher(&watcher);
    if (result != 0) {
        ssh_askpass_native_wipe(buffer, capacity);
        *out_length = 0;
    }
    return result;
}

int ssh_askpass_native_wait_for_parent_exit(pid_t parent_pid, int timeout_milliseconds) {
    if (parent_pid <= 1 || getppid() != parent_pid) return 1;
    struct timespec deadline;
    if (timeout_milliseconds >= 0) {
        if (clock_gettime(CLOCK_MONOTONIC, &deadline) != 0) return getppid() != parent_pid;
        deadline.tv_sec += timeout_milliseconds / 1000;
        deadline.tv_nsec += (timeout_milliseconds % 1000) * 1000000L;
        if (deadline.tv_nsec >= 1000000000L) {
            deadline.tv_sec++;
            deadline.tv_nsec -= 1000000000L;
        }
    }

    int queue = kqueue();
    if (queue >= 0 && set_close_on_exec(queue)) {
        struct kevent change;
        EV_SET(&change, (uintptr_t)parent_pid, EVFILT_PROC, EV_ADD | EV_ENABLE, NOTE_EXIT, 0, NULL);
        if (kevent(queue, &change, 1, NULL, 0, NULL) == 0) {
            for (;;) {
                if (getppid() != parent_pid) {
                    (void)close(queue);
                    return 1;
                }
                struct timespec timeout;
                struct timespec *timeout_pointer = NULL;
                if (timeout_milliseconds >= 0) {
                    struct timespec now;
                    if (clock_gettime(CLOCK_MONOTONIC, &now) != 0 || deadline_reached(&deadline)) {
                        (void)close(queue);
                        return getppid() != parent_pid;
                    }
                    timeout.tv_sec = deadline.tv_sec - now.tv_sec;
                    timeout.tv_nsec = deadline.tv_nsec - now.tv_nsec;
                    if (timeout.tv_nsec < 0) {
                        timeout.tv_sec--;
                        timeout.tv_nsec += 1000000000L;
                    }
                    timeout_pointer = &timeout;
                }
                struct kevent event;
                int count = kevent(queue, NULL, 0, &event, 1, timeout_pointer);
                if (count > 0) {
                    (void)close(queue);
                    return 1;
                }
                if (count == 0) {
                    (void)close(queue);
                    return getppid() != parent_pid;
                }
                if (errno != EINTR) break;
            }
        }
        (void)close(queue);
    } else if (queue >= 0) {
        (void)close(queue);
    }

    for (;;) {
        if (getppid() != parent_pid) return 1;
        if (timeout_milliseconds >= 0 && deadline_reached(&deadline)) return 0;
        short_pause();
    }
}

int ssh_askpass_native_install_fatal_handlers(pid_t parent_pid) {
    fatal_parent = parent_pid;
    fatal_stack.ss_sp = fatal_stack_storage;
    fatal_stack.ss_size = sizeof(fatal_stack_storage);
    fatal_stack.ss_flags = 0;
    if (sigaltstack(&fatal_stack, NULL) != 0) return -1;
    struct sigaction action;
    memset(&action, 0, sizeof(action));
    action.sa_handler = fatal_handler;
    sigemptyset(&action.sa_mask);
    action.sa_flags = SA_RESETHAND | SA_ONSTACK;
    for (size_t i = 0; i < sizeof(fatal_signals) / sizeof(fatal_signals[0]); i++) {
        if (sigaction(fatal_signals[i], &action, &saved_fatal_actions[i]) != 0) {
            while (i-- > 0) (void)sigaction(fatal_signals[i], &saved_fatal_actions[i], NULL);
            fatal_parent = 0;
            return -1;
        }
    }
    return 0;
}

void ssh_askpass_native_restore_fatal_handlers(void) {
    for (size_t i = 0; i < sizeof(fatal_signals) / sizeof(fatal_signals[0]); i++) {
        (void)sigaction(fatal_signals[i], &saved_fatal_actions[i], NULL);
    }
    fatal_parent = 0;
}

void ssh_askpass_native_wipe(void *buffer, size_t length) {
    if (buffer != NULL && length > 0) (void)memset_s(buffer, length, 0, length);
}
