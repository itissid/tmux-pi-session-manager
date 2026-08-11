#!/usr/bin/env bash
# Safe-kill tests for scripts/kill.sh.
set -u
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=../scripts/helpers.sh
. "$ROOT/scripts/helpers.sh"

SUITE_NAME="kill"

make_sandbox
install_mocks

# scenario: two pi agents (301 loose, 302 dedicated) + a decoy (303) in its
# own session t2 that is discoverable as pi but vanishes before kill
# re-verifies (TOCTOU race).
make_proc_pid 301 pi 34822 1000 /usr/bin/node "$SB/projA"
make_proc_pid 302 pi 34824 2000 /usr/bin/node "$SB/projA"
make_proc_pid 303 pi 34826 3000 /usr/bin/node "$SB/projB"
tmux_set_panes \
  $'pts/6\t%1\tt1\tt1:1.1' \
  $'pts/8\t%2\tt1\tt1:1.2' \
  $'pts/10\t%3\tt2\tt2:1.1'
tmux_set_marker t1 @pi_tmux_managed 1
tmux_set_marker t2 @pi_tmux_managed 1
# state files so kill-cleanup can be observed (one per live agent)
write_state "sess-301" "$(printf '{"session_id":"sess-301","pid":301,"status":"waiting","cwd":"%s"}' "$SB/projA")"
write_state "sess-302" "$(printf '{"session_id":"sess-302","pid":302,"status":"waiting","cwd":"%s"}' "$SB/projA")"

t_section "rejects a process that vanished during discovery (race)"
# the mock tmux removes /proc/303 when the pane map is read (list-panes) —
# the pid is already gone before the /proc scan, so kill must refuse without
# signalling (a process that cannot be re-verified is never signalled).
out="$(PSM_TMUX_RACE_SESSION=t2 PSM_TMUX_RACE_PID=303 "$ROOT/scripts/kill.sh" 303 --yes 2>&1)"
assert_eq "race refusal exit code" "$?" "1"
assert_contains "race refusal message" "$out" "pi-tmux:"
assert_no_file "no signal sent to racy pid" "$PSM_KILL_LOG"

t_section "graceful kill (TERM only)"
PSM_KILL_REALLY_DIES=1 "$ROOT/scripts/kill.sh" 301 --yes >/dev/null 2>&1
klog="$(cat "$PSM_KILL_LOG" 2>/dev/null)"
assert_contains "SIGTERM sent" "$klog" "-TERM 301"
assert_not_contains "no SIGKILL when clean" "$klog" "KILL 301"
assert_no_file "state cleaned after graceful kill" "$(psm_state_dir)/agents/sess-301.json"

# restore 301 for later tests
make_proc_pid 301 pi 34822 1000 /usr/bin/node "$SB/projA"

t_section "escalation to SIGKILL"
rm -f "$PSM_KILL_LOG"
PSM_KILL_GRACE=1 "$ROOT/scripts/kill.sh" 302 --yes >/dev/null 2>&1
klog="$(cat "$PSM_KILL_LOG" 2>/dev/null)"
assert_contains "SIGTERM first" "$klog" "-TERM 302"
assert_contains "SIGKILL after grace" "$klog" "-KILL 302"
# kill failed, so the state file must NOT be cleaned up
assert_file "state kept when kill fails" "$(psm_state_dir)/agents/sess-302.json"

t_section "unknown target"
out="$("$ROOT/scripts/kill.sh" 999999 --yes 2>&1)"
assert_eq "unknown target exit" "$?" "1"
assert_contains "unknown target message" "$out" 'no running pi agent matches'

mkdir -p "$TEST_ROOT/results"
printf '%s %s\n' "$PASS" "$FAIL" > "$TEST_ROOT/results/$SUITE_NAME"
