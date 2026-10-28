#!/bin/sh
# Owns one tunnel ssh process for the lifetime of the app that started it.
#
# Usage: /bin/sh chostty-ssh-tunnel-watchdog.sh <owner pid> <pid file> -- ssh <arguments...>
#
# <owner pid> is the app's own pid. If the app is gone before this script
# runs, it exits 75 without starting ssh.
#
# Standard input is the app's lifeline pipe. EOF on it, or this script being
# reparented away from its starting parent, means the app is gone: ssh gets
# SIGTERM, then SIGKILL after two seconds. The reparenting check exists
# because Darwin has no pipe2, so a pane forked between pipe() and FD_CLOEXEC
# can inherit the lifeline write end and keep EOF from arriving.
# When ssh exits first, this script exits with its status.
set -u

if [ "$#" -lt 4 ] || [ "$3" != "--" ]; then
    exit 64
fi
owner=$1
pid_file=$2
shift 3

if [ "$PPID" != "$owner" ]; then
    exit 75
fi
stop_requested=0
trap 'stop_requested=1' USR1 TERM HUP INT

# Asynchronous lists read /dev/null unless redirected explicitly, so keep the
# lifeline on descriptor 3 for the reader.
exec 3<&0 0</dev/null

"$@" 3<&- &
ssh_pid=$!
# The askpass token belongs to ssh alone, not to the helpers started below.
unset CHOSTTY_ASKPASS_TOKEN CHOSTTY_ASKPASS_SOCKET CHOSTTY_ASKPASS_TUNNEL SSH_ASKPASS SSH_ASKPASS_REQUIRE

umask 077
printf '%s\n' "$ssh_pid" >"$pid_file.$$" && /bin/mv -f "$pid_file.$$" "$pid_file"

watchdog_pid=$$

# True while the calling helper subshell is still this script's child. A
# helper orphaned by a SIGKILLed watchdog stops instead of signalling a
# reused pid. The exec makes the probe's parent the helper itself.
watchdog_is_parent() {
    helper=$(exec /bin/sh -c 'echo "$PPID"')
    [ "$(/bin/ps -o ppid= -p "$helper" | /usr/bin/tr -d ' ')" = "$watchdog_pid" ]
}

# Both watchers repeat the signal so one landing just before wait is not lost.
# Helpers never hold the ssh stderr pipe, so the app sees EOF when ssh ends.
notify_until_gone() {
    while watchdog_is_parent; do
        kill -USR1 "$watchdog_pid" 2>/dev/null
        /bin/sleep 1
    done
}

(
    /bin/cat <&3 >/dev/null
    notify_until_gone
) >/dev/null 2>&1 &
reader_pid=$!
exec 3<&-

(
    while [ "$(/bin/ps -o ppid= -p "$watchdog_pid" | /usr/bin/tr -d ' ')" = "$owner" ]; do
        /bin/sleep 1
    done
    notify_until_gone
) >/dev/null 2>&1 &
parent_watcher_pid=$!

status=0
while [ "$stop_requested" = 0 ]; do
    wait "$ssh_pid"
    status=$?
    if [ "$stop_requested" = 0 ]; then
        kill "$reader_pid" "$parent_watcher_pid" 2>/dev/null
        exit "$status"
    fi
done

kill -TERM "$ssh_pid" 2>/dev/null
(
    /bin/sleep 2
    if watchdog_is_parent; then
        kill -KILL "$ssh_pid" 2>/dev/null
    fi
) >/dev/null 2>&1 &
killer_pid=$!
while kill -0 "$ssh_pid" 2>/dev/null; do
    wait "$ssh_pid"
done
kill "$killer_pid" "$reader_pid" "$parent_watcher_pid" 2>/dev/null
exit 0
