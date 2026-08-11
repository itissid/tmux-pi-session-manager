#!/usr/bin/env bash
# CLI tests for bin/pi-tmux.
set -u
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=../scripts/helpers.sh
. "$ROOT/scripts/helpers.sh"

SUITE_NAME="cli"

make_sandbox
install_mocks

CLI="$ROOT/bin/pi-tmux"

make_proc_pid 501 pi 34822 1000 /usr/bin/node "$SB/projA"
make_proc_pid 502 pi 34824 2000 /usr/bin/node "$SB/projA"
tmux_set_panes \
  $'pts/6\t%1\tt1\tt1:1.1' \
  $'pts/8\t%2\tt1\tt1:1.2'

t_section "list --json"
out="$("$CLI" list --json)"
assert_eq "json parses" "$(printf '%s' "$out" | jq -r 'length')" "2"
assert_eq "json pid field" "$(printf '%s' "$out" | jq -r '.[0].pid')" "502"
assert_eq "json status plain" "$(printf '%s' "$out" | jq -r '.[0].status')" "unknown"
assert_eq "json loc" "$(printf '%s' "$out" | jq -r '.[0].loc')" "t1:1.2"
assert_contains "json dir" "$out" "$SB/projA"

t_section "version"
assert_contains "version prints" "$("$CLI" version)" "pi-tmux"

t_section "current"
tmux_set_display "%1"
out="$("$CLI" current)"
assert_contains "current row" "$out" "projA #"
tmux_set_display "%99"
out="$("$CLI" current 2>&1)"
assert_eq "current none exit" "$?" "1"
assert_contains "current none message" "$out" "no pi agent"

t_section "status shows state json when present"
sid="019ff17a-ea8b-760c-9d2a-8de4a1bafd62"
write_state "$sid" "$(printf '{"session_id":"%s","pid":501,"status":"waiting","cwd":"%s"}' "$sid" "$SB/projA")"
out="$("$CLI" status "$sid")"
assert_contains "status json" "$out" '"status": "waiting"'
out="$("$CLI" status 502)"
assert_contains "status fallback row" "$out" $'\tloose\tpid:502'

t_section "launch (no attach) creates dedicated session with env prefix"
tmux_set_sessions ""
out="$("$CLI" launch --dir "$SB/projA" --window '%1' --no-attach 2>&1)"
assert_contains "launch message" "$out" "launched pi agent"
log="$(tmux_log)"
assert_contains "new-session called" "$log" "new-session -d -s pi-"
assert_contains "cwd passed" "$log" "-c $SB/projA"
assert_contains "managed marker set" "$log" "@pi_tmux_managed 1"
assert_contains "origin window set" "$log" "@pi_tmux_origin %1"
assert_contains "env prefix injected" "$log" "env PSM_STATE_DIR=$PSM_STATE_DIR"
ns="$(grep 'new-session' "$PSM_TMUX_LOG" | tail -n1)"
case "$ns" in
  *" pi") t_ok "pi command last" ;;
  *) t_fail "pi command last" "new-session line: [$ns]" ;;
esac

t_section "launch refuses nesting inside a managed session"
tmux_set_display "pi-aaaaaaaa"
tmux_set_marker "pi-aaaaaaaa" @pi_tmux_managed 1
out="$("$CLI" launch --dir "$SB/projA" --no-attach 2>&1)"
assert_eq "nesting refused exit" "$?" "1"
assert_contains "nesting message" "$out" "already inside a pi agent session"

t_section "launch resume"
tmux_set_display ""
mkdir -p "$SB/pi-agent/sessions/--tmp-psm-tests-zzz--"
printf '{"cwd":"%s"}\n' "$SB/projA" > "$SB/pi-agent/sessions/--tmp-psm-tests-zzz--/x_019ff17a-ea8b.jsonl"
out="$("$CLI" resume 019ff17a-ea8b --no-attach 2>&1)"
assert_contains "resume message" "$out" "resuming session"
assert_contains "resume flag" "$(tmux_log)" "--session"

t_section "install / uninstall extension"
"$CLI" install-extension >/dev/null 2>&1
assert_file "extension installed" "$(pi_extensions_dir)/pi-tmux-session-manager.ts"
"$CLI" uninstall-extension >/dev/null 2>&1
assert_no_file "extension removed" "$(pi_extensions_dir)/pi-tmux-session-manager.ts"

t_section "doctor"
out="$("$CLI" doctor)"
assert_contains "doctor mentions tmux" "$out" "tmux"
assert_contains "doctor state dir" "$out" "$PSM_STATE_DIR"

t_section "unknown command"
out="$("$CLI" bogus 2>&1)"
assert_eq "unknown command exit" "$?" "2"

mkdir -p "$TEST_ROOT/results"
printf '%s %s\n' "$PASS" "$FAIL" > "$TEST_ROOT/results/$SUITE_NAME"
