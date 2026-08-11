#!/usr/bin/env bash
# Notification dedup/gating tests for scripts/notify.sh.
set -u
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=../scripts/helpers.sh
. "$ROOT/scripts/helpers.sh"

SUITE_NAME="notify"

make_sandbox
install_mocks

now="$(date +%s)"
make_proc_pid 401 pi 34822 1000 /usr/bin/node "$SB/projA"

state_file() { printf '%s' "$(psm_state_dir)/agents/sess-401.json"; }

t_section "waiting triggers notification (once)"
write_state "sess-401" "$(printf '{"session_id":"sess-401","pid":401,"status":"waiting","cwd":"%s","started_at":%s,"last_stop_reason":"stop"}' "$SB/projA" "$((now * 1000 - 60000))")"
"$ROOT/scripts/notify.sh" >/dev/null 2>&1
nlog="$(cat "$PSM_NOTIFY_LOG" 2>/dev/null)"
assert_contains "waiting notification sent" "$nlog" "waiting for input"
assert_eq "marker recorded" "$(jq -r '.notify.last_sent_status' "$(state_file)")" "waiting"

rm -f "$PSM_NOTIFY_LOG"
"$ROOT/scripts/notify.sh" >/dev/null 2>&1
assert_no_file "dedup: no second notification" "$PSM_NOTIFY_LOG"

t_section "waiting -> working -> waiting re-notifies"
write_state "sess-401" "$(jq '.status = "working"' "$(state_file)")"
"$ROOT/scripts/notify.sh" >/dev/null 2>&1
assert_no_file "working status does not notify (default config)" "$PSM_NOTIFY_LOG"
write_state "sess-401" "$(jq '.status = "waiting"' "$(state_file)")"
"$ROOT/scripts/notify.sh" >/dev/null 2>&1
nlog="$(cat "$PSM_NOTIFY_LOG" 2>/dev/null)"
assert_contains "re-notify after working cycle" "$nlog" "waiting for input"

t_section "min_attention_duration gates waiting notifications"
mkdir -p "$PSM_CONFIG_DIR"
printf '{"min_attention_duration_ms":60000}\n' > "$(psm_config_file)"
write_state "sess-401" "$(printf '{"session_id":"sess-401","pid":401,"status":"waiting","cwd":"%s","started_at":%s,"last_stop_reason":"stop","notify":{"last_sent_status":null,"last_sent_at":null}}' "$SB/projA" "$((now * 1000))")"
rm -f "$PSM_NOTIFY_LOG"
"$ROOT/scripts/notify.sh" >/dev/null 2>&1
assert_no_file "too-young waiting suppressed" "$PSM_NOTIFY_LOG"
# now let enough time pass (rewrite with an old started_at)
write_state "sess-401" "$(printf '{"session_id":"sess-401","pid":401,"status":"waiting","cwd":"%s","started_at":%s,"last_stop_reason":"stop","notify":{"last_sent_status":null,"last_sent_at":null}}' "$SB/projA" "$((now * 1000 - 120000))")"
rm -f "$PSM_NOTIFY_LOG"
"$ROOT/scripts/notify.sh" >/dev/null 2>&1
assert_file "mature waiting notifies" "$PSM_NOTIFY_LOG"

t_section "error notifications and config gate"
printf '{"notify_on_error":false}\n' > "$(psm_config_file)"
write_state "sess-401" "$(jq '.status = "error"' "$(state_file)")"
rm -f "$PSM_NOTIFY_LOG"
"$ROOT/scripts/notify.sh" >/dev/null 2>&1
assert_no_file "notify_on_error=false suppresses" "$PSM_NOTIFY_LOG"
printf '{"notify_on_error":true}\n' > "$(psm_config_file)"
rm -f "$PSM_NOTIFY_LOG"
"$ROOT/scripts/notify.sh" >/dev/null 2>&1
nlog="$(cat "$PSM_NOTIFY_LOG" 2>/dev/null)"
assert_contains "error notification sent" "$nlog" "agent error"
rm -f "$PSM_NOTIFY_LOG"
"$ROOT/scripts/notify.sh" >/dev/null 2>&1
assert_no_file "error dedup" "$PSM_NOTIFY_LOG"

t_section "stale state removed without notification"
write_state "sess-401" "$(printf '{"session_id":"sess-401","pid":402,"status":"waiting","cwd":"%s"}' "$SB/projA")"
rm -f "$PSM_NOTIFY_LOG"
"$ROOT/scripts/notify.sh" >/dev/null 2>&1
assert_no_file "dead agent: no notification" "$PSM_NOTIFY_LOG"
assert_no_file "dead agent: state removed" "$(state_file)"

t_section "notify_id is stable"
# source notify.sh without running main() to reuse notify_id
# shellcheck disable=SC1090
. <(sed '/^main "\$@"$/d' "$ROOT/scripts/notify.sh") 2>/dev/null
id1="$(notify_id '019ff17a-ea8b-760c-9d2a-8de4a1bafd62')"
id2="$(notify_id '019ff17a-ea8b-760c-9d2a-8de4a1bafd62')"
assert_eq "notify_id deterministic" "$id1" "$id2"
id3="$(notify_id 'some-other-session-id')"
assert_not_contains "notify_id differs per session" "$id1" "$id3"
if [ "$id1" -gt 0 ] 2>/dev/null && [ "$id1" -le 2147483647 ] 2>/dev/null; then
  t_ok "notify_id in signed 32-bit range"
else
  t_fail "notify_id in signed 32-bit range" "got $id1"
fi

mkdir -p "$TEST_ROOT/results"
printf '%s %s\n' "$PASS" "$FAIL" > "$TEST_ROOT/results/$SUITE_NAME"
