#!/usr/bin/env bash
# End-to-end check of a piece against a real irssi and a real IRC server.
#
# Usage: scripts/e2e.sh [piece] (default: zeta)
#
# Starts a listener client in a channel, runs irssi in a detached tmux session,
# loads src/mathascii.pl, sends the piece with /math, and compares the bytes the
# listener received with what scripts/render.pl produces. Needs an IRC server
# that allows unregistered clients, set by E2E_HOST and E2E_PORT (default
# 127.0.0.1:6667, the local ergo).
#
# Prints PASS or FAIL. Everything else (irssi's screen, both line dumps, the
# listener's log) is kept in the work directory it names.
set -euo pipefail

piece=${1:-zeta}
host=${E2E_HOST:-127.0.0.1}
port=${E2E_PORT:-6667}
here=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/mathascii-e2e.XXXXXX")
channel="#mathascii-e2e-$$"
session="mathascii-e2e-$$"

cleanup() {
    tmux kill-session -t "$session" 2>/dev/null || true
    [[ -n ${listener:-} ]] && kill "$listener" 2>/dev/null || true
}
trap cleanup EXIT

wait_for() {
    local what=$1 seconds=$2 check=$3
    for ((i = 0; i < seconds * 10; i++)); do
        eval "$check" && return 0
        sleep 0.1
    done
    # Script load errors land in the status window, so grab that too.
    tmux capture-pane -pt "$session" > "$work/irssi-screen.txt" 2>/dev/null || true
    tmux send-keys -t "$session" "/window 1" Enter 2>/dev/null && sleep 0.5 &&
        tmux capture-pane -pt "$session" > "$work/irssi-status.txt" 2>/dev/null || true
    echo "FAIL: timed out waiting for $what. logs in $work"
    exit 1
}

"$here/scripts/render.pl" "$piece" > "$work/expected.txt"
expected_lines=$(wc -l < "$work/expected.txt")

"$here/scripts/irc-listener.pl" "$host" "$port" "watch$$" "$channel" "$work/received.txt" \
    2> "$work/listener.log" &
listener=$!
wait_for "the listener to join $channel" 15 "[[ -f '$work/received.txt.ready' ]]"

# A fresh irssi home keeps your real config out of it. The queue speed is
# lowered so the test doesn't take a minute. irssi reads it when a server
# connects, so it has to be set before /connect.
mkdir -p "$work/irssi"
tmux new-session -d -s "$session" -x 120 -y 50 "irssi --home='$work/irssi' -!"
send() { tmux send-keys -t "$session" "$1" Enter; }
send "/set nick math$$"
send "/set cmd_queue_speed 200msec"
send "/connect $host $port"
wait_for "irssi to connect" 15 \
    "tmux capture-pane -pt '$session' | grep -q 'Your user mode is'"
send "/join $channel"
# irssi opens the channel window before the server confirms the join, and
# anything sent in that gap gets dropped, so wait for the nick list.
wait_for "irssi to join $channel" 15 "tmux capture-pane -pt '$session' | grep -q 'Total of 2 nicks'"
send "/script load $here/src/mathascii.pl"
send "/math $piece"
# Lines arrive about 2.7s apart here even with the queue speed lowered, for
# reasons we haven't pinned down, so allow 4s a line.
wait_for "$expected_lines lines to arrive" $((expected_lines * 4 + 10)) \
    "[[ \$(wc -l < '$work/received.txt') -ge $expected_lines ]]"
tmux capture-pane -ept "$session" > "$work/irssi-screen.txt"

if cmp -s "$work/expected.txt" "$work/received.txt"; then
    echo "PASS: $piece arrived byte for byte ($expected_lines lines). logs in $work"
else
    echo "FAIL: what arrived differs from render.pl. diff:"
    diff "$work/expected.txt" "$work/received.txt" | cat -v | head -20
    echo "logs in $work"
    exit 1
fi
