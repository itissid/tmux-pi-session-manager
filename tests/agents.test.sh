#!/usr/bin/env bash
# Discovery tests for scripts/agents.sh.
set -u
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=../scripts/helpers.sh
. "$ROOT/scripts/helpers.sh"

SUITE_NAME="agents"

make_sandbox
install_mocks

rows() { "$ROOT/scripts/agents.sh"; }

t_section "two loose agents, no extension state"
make_proc_pid 201 pi 34822 1000 /usr/bin/node "$SB/projA"
make_proc_pid 202 pi 34824 2000 /usr/bin/node "$SB/projA"   # same dir, newer
tmux_set_panes \
  $'pts/6\t%1\tt1\tt1:1.1' \
  $'pts/8\t%2\tt1\tt1:1.2'
out="$(rows)"
assert_contains "finds both agents" "$out" $'%1'
assert_contains "second pane present" "$out" $'%2'
n="$(printf '%s\n' "$out" | wc -l)"
assert_eq "two rows" "$n" "2"
assert_contains "unknown status rank 5" "$out" $'5\t%1'
assert_contains "fallback session id pid:201" "$out" 'pid:201'
assert_contains "loose kind" "$out" $'loose\tpid:201'
assert_contains "loc format sess:win.pane" "$out" 't1:1.1'
assert_contains "cwd displayed" "$out" "$SB/projA"
# per-directory suffix for the visible project column
assert_contains "first agent #1" "$out" 'projA #1'
assert_contains "second agent #2" "$out" 'projA #2'
# newer agent (202) sorted first within same rank
first="$(printf '%s\n' "$out" | head -n1 | cut -f3)"
assert_eq "newer agent sorted first" "$first" "202"

t_section "extension state enriches status"
mkdir -p "$(psm_state_dir)/agents"
now="$(date +%s)"
write_state "sess-aaa" "$(printf '{"session_id":"sess-aaa","pid":201,"status":"working","cwd":"%s","started_at":%s,"last_activity_at":%s,"session_name":"api","alive":true}' "$SB/projA" "$((now * 1000))" "$((now * 1000))")"
out="$(rows)"
assert_contains "session id from state" "$out" 'sess-aaa'
assert_contains "working rank 3" "$out" $'3\t%1'
assert_contains "WORKING label" "$out" 'WORKING'
assert_contains "project from session_name" "$out" $'\tapi #2\t'
assert_not_contains "no basename fallback for named agent" "$out" $'projA #2'

t_section "dedicated sessions (launcher marker)"
tmux_set_marker t1 @pi_tmux_managed 1
out="$(rows)"
assert_contains "dedicated kind" "$out" $'dedicated\tsess-aaa'
assert_not_contains "201 row still loose-free" "$out" $'loose\t201'

t_section "status priority: error < waiting < working < idle < unknown"
make_proc_pid 203 pi 34826 3000 /usr/bin/node "$SB/projB"
make_proc_pid 204 pi 34828 4000 /usr/bin/node "$SB/projB"
make_proc_pid 205 pi 34830 5000 /usr/bin/node "$SB/projB"
tmux_set_panes \
  $'pts/6\t%1\tt1\tt1:1.1' \
  $'pts/8\t%2\tt1\tt1:1.2' \
  $'pts/10\t%3\tt1\tt1:2.1' \
  $'pts/12\t%4\tt1\tt1:2.2' \
  $'pts/14\t%5\tt1\tt1:2.3'
now="$(date +%s)"
# demote the earlier 201 (was working) so 205 is the only rank-2 working agent
write_state "sess-aaa" "$(printf '{"pid":201,"status":"idle","cwd":"%s","started_at":%s,"last_activity_at":%s,"alive":true}' "$SB/projA" "$((now * 1000 - 5000000))" "$((now * 1000 - 5000000))")"
write_state "sess-err"  "$(printf '{"pid":203,"status":"error","cwd":"%s","started_at":%s}' "$SB/projB" "$((now * 1000))")"
write_state "sess-wait" "$(printf '{"pid":204,"status":"waiting","cwd":"%s","started_at":%s}' "$SB/projB" "$((now * 1000))")"
write_state "sess-work" "$(printf '{"pid":205,"status":"working","cwd":"%s","started_at":%s}' "$SB/projB" "$((now * 1000))")"
out="$(rows)"
first="$(printf '%s\n' "$out" | head -n1 | cut -f3)"
assert_eq "error ranks first" "$first" "203"
second="$(printf '%s\n' "$out" | sed -n 2p | cut -f3)"
assert_eq "waiting ranks second" "$second" "204"
third="$(printf '%s\n' "$out" | sed -n 3p | cut -f3)"
assert_eq "working ranks third" "$third" "205"

t_section "blocked status outranks everything and is_blocked overrides"
# make 203 blocked (it also has an error — blocked wins)
write_state "sess-err" "$(printf '{"pid":203,"status":"blocked","cwd":"%s","started_at":%s,"is_blocked":true}' "$SB/projB" "$((now * 1000))")"
# make 204 blocked via the is_blocked flag while status says working (race guard)
write_state "sess-wait" "$(printf '{"pid":204,"status":"working","cwd":"%s","started_at":%s,"is_blocked":true}' "$SB/projB" "$((now * 1000))")"
out="$(rows)"
first="$(printf '%s\n' "$out" | head -n1 | cut -f3)"
assert_eq "blocked ranks first" "$first" "203"
assert_contains "BLOCKED label shown" "$out" "BLOCKED"
second="$(printf '%s\n' "$out" | sed -n 2p | cut -f3)"
assert_eq "is_blocked override ranks second" "$second" "204"
assert_not_contains "override beats status field" "$out" $'working\t'

t_section "stale state cleanup"
mkdir -p "$(psm_state_dir)/agents"
printf '{"pid":99999,"status":"waiting"}\n' > "$(psm_state_dir)/agents/sess-stale.json"
out="$(rows)"
assert_no_file "stale state removed" "$(psm_state_dir)/agents/sess-stale.json"
assert_not_contains "no row for dead pid" "$out" "99999"

t_section "pid without tty is skipped"
make_proc_pid 206 pi 0 6000 /usr/bin/node "$SB/projC"
out="$(rows)"
assert_not_contains "tty-less pi skipped" "$out" "206"

t_section "session-file fallback age (no extension)"
# a session file for projA with a header cwd match gives the row its age
enc="${SB#/}"; enc="${enc//\//-}"
mkdir -p "$SB/pi-agent/sessions/--${enc}-projA--"
ts="$(date -u +%Y-%m-%dT%H:%M:%S)"
printf '{"cwd":"%s","timestamp":"%s"}\n' "$SB/projA" "$ts" > "$SB/pi-agent/sessions/--${enc}-projA--/file.jsonl"
# agent 202 has no state file; its fallback age comes from the session file
out="$(rows)"
assert_contains "age visible" "$out" $'\tprojA #2\t'
# and session file mtime fallback works without crashing
bash -n "$ROOT/scripts/agents.sh" && t_ok "agents.sh parses" || t_fail "agents.sh parses" "syntax error"

mkdir -p "$TEST_ROOT/results"
printf '%s %s\n' "$PASS" "$FAIL" > "$TEST_ROOT/results/$SUITE_NAME"
