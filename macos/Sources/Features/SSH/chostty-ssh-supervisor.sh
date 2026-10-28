#!/bin/sh
set -u
umask 077
# The app owns control O_RDWR for the pane lifetime, so a failed FIFO read here
# is an interrupted read, not EOF. Keep supervising after INT/QUIT.
trap ':' INT QUIT
trap '' TSTP TTIN TTOU

runtime_directory=$1
login_path=$2
ssh_auth_sock=$3
askpass_socket=$4
shift 4
[ "${1-}" = "--" ] && shift
askpass_app=$1

state_file="$runtime_directory/state"
temporary_state_file="$runtime_directory/state.tmp"
control_file="$runtime_directory/control"
ever_file="$runtime_directory/ever"
sequence=0
connection_token=

write_state() {
    printf '%s\n' "$1" >"$temporary_state_file"
    mv -f "$temporary_state_file" "$state_file"
}

reset_terminal_modes() {
    # 1049l restores a cursor even on the primary screen. Save this screen's
    # cursor first so reconnect output cannot overwrite earlier primary output.
    printf '\0337\033[?1049l'
    printf '\033[?1000l\033[?1002l\033[?1003l\033[?1006l'
    printf '\033[?1004l\033[?25h\033[?1l\033>\033[>u\033[0m'
}

start_reader() {
    reader_sequence=$1
    (
        paste=0
        pending=
        idle=1
        return_candidate=0
        input_file="$runtime_directory/input.$reader_sequence.$$"
        bytes_file="$input_file.bytes"
        start_sequence='27 91 50 48 48 126'
        end_sequence='27 91 50 48 49 126'
        trap 'kill "${byte_reader-}" 2>/dev/null || :; wait "${byte_reader-}" 2>/dev/null || :; rm -f "$input_file" "$bytes_file"; exit 0' TERM
        while :; do
            dd bs=1024 count=1 </dev/tty >"$input_file" 2>/dev/null &
            byte_reader=$!
            wait "$byte_reader" || exit 0
            od -An -tu1 "$input_file" | tr -s '[:space:]' '\n' >"$bytes_file"
            byte_count=$(grep -c . "$bytes_file")
            if [ "$byte_count" -eq 0 ]; then
                if [ "$return_candidate" = 1 ]; then
                    return_candidate=0
                    write_state "connect-requested $reader_sequence"
                fi
                idle=1
                continue
            fi
            return_candidate=0
            while IFS= read -r byte; do
                [ -n "$byte" ] || continue
                previous=$pending
                pending="${pending:+$pending }$byte"
                if [ "$paste" = 1 ]; then
                    case $pending in
                        "$end_sequence")
                            paste=0
                            pending=
                            ;;
                        27|27\ 91|27\ 91\ 50|27\ 91\ 50\ 48|27\ 91\ 50\ 48\ 49) ;;
                        *)
                            [ "$byte" = 27 ] && pending=27 || pending=
                            ;;
                    esac
                    continue
                fi

                case $pending in
                    "$start_sequence")
                        paste=1
                        pending=
                        ;;
                    27|27\ 91|27\ 91\ 50|27\ 91\ 50\ 48|27\ 91\ 50\ 48\ 48) ;;
                    *)
                        pending=
                        if [ "$idle" = 1 ] && [ "$byte_count" = 1 ] && [ -z "$previous" ] &&
                            { [ "$byte" = 10 ] || [ "$byte" = 13 ]; }; then
                            return_candidate=1
                        fi
                        ;;
                esac
            done <"$bytes_file"
            idle=0
        done
    ) &
    reader=$!
}

stop_reader() {
    kill "$reader" 2>/dev/null || :
    wait "$reader" 2>/dev/null || :
}

wait_for_command() {
    waiting_kind=$1
    waiting_status=${2-}
    waiting_ever=${3-}
    # Ignoring signals while reading avoids discarding a completed FIFO line
    # when a trapped INT makes the shell's read return an interrupted status.
    trap '' INT QUIT
    # min 0/time 1 gives the reader an idle boundary: only an isolated Return
    # requests reconnect, while pasted or multi-byte chunks remain discarded.
    stty -echo -icanon -isig min 0 time 1 </dev/tty
    printf '\033[?2004h'
    start_reader "$sequence"

    while :; do
        if ! IFS=' ' read -r command next_sequence token extra <&3; then
            continue
        fi
        case $command in
            connect)
                [ -z "$extra" ] || continue
                case $token in
                    -) ;;
                    ''|*[!0123456789abcdef]*) continue ;;
                    *) [ "${#token}" -eq 64 ] || continue ;;
                esac
                ;;
            deny) ;;
            *) continue ;;
        esac
        case $next_sequence in ''|*[!0-9]*) continue ;; esac
        [ "$next_sequence" -gt "$sequence" ] || continue

        stop_reader
        sequence=$next_sequence
        if [ "$command" = connect ]; then
            if [ "$token" = '-' ]; then
                connection_token=
            else
                connection_token=$token
            fi
            # Caught (rather than ignored) signals reset to defaults in SSH.
            trap ':' INT QUIT
            stty "$base" </dev/tty
            return
        fi

        case $waiting_kind in
            waiting) write_state "waiting $sequence" ;;
            exited) write_state "exited $sequence $waiting_status $waiting_ever" ;;
        esac
        start_reader "$sequence"
    done
}

base=$(stty -g </dev/tty)
export PATH=$login_path
if [ "$ssh_auth_sock" != '-' ]; then
    export SSH_AUTH_SOCK=$ssh_auth_sock
fi
printf '%s\n' "$$" >"$runtime_directory/pid"
exec 3<"$control_file"

write_state "waiting 0"
wait_for_command waiting
while :; do
    rm -f "$ever_file"

    stty -icanon min 0 time 0 </dev/tty
    dd bs=1024 count=1 of=/dev/null 2>/dev/null || :
    stty "$base" </dev/tty
    printf '\033[?2004l\033]133;C\007'
    write_state "connecting $sequence"
    (
        # $$ is still the supervisor here. Without it or its terminal the
        # poller would loop forever as an orphan.
        while kill -0 "$$" 2>/dev/null; do
            tty_flags=$(stty -a </dev/tty) || exit 0
            case " $tty_flags " in
                *" -icanon "*)
                    case " $tty_flags " in
                        *" -isig "*)
                            : >"$ever_file"
                            write_state "connected $sequence"
                            exit 0
                            ;;
                    esac
                ;;
            esac
            sleep 0.3
        done
    ) &
    poller=$!

    if [ -n "$connection_token" ]; then
        /usr/bin/env -u SSH_ASKPASS_PROMPT \
            SSH_ASKPASS="$askpass_app" \
            SSH_ASKPASS_REQUIRE=force \
            DISPLAY="${DISPLAY:-:0}" \
            CHOSTTY_ASKPASS_SOCKET="$askpass_socket" \
            CHOSTTY_ASKPASS_TOKEN="$connection_token" \
            "$@"
    else
        # No saved password: OpenSSH asks in the terminal as it always does.
        "$@"
    fi
    status=$?
    kill "$poller" 2>/dev/null || :
    wait "$poller" 2>/dev/null || :
    if [ -f "$ever_file" ]; then
        ever_connected=1
    else
        ever_connected=0
    fi
    write_state "exited $sequence $status $ever_connected"
    if [ "$ever_connected" = 1 ] && [ "$status" -ne 255 ]; then
        exit 0
    fi

    reset_terminal_modes
    printf '[ssh exited with status %s]\n\033]133;A\007' "$status"
    printf '— press Return to reconnect\n'
    wait_for_command exited "$status" "$ever_connected"
done
