#!/usr/bin/env bash
# Unit tests for scripts/helpers.sh.
set -u
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=../scripts/helpers.sh
. "$ROOT/scripts/helpers.sh"

SUITE_NAME="helpers"

make_sandbox
install_mocks

t_section "hashing & naming"
h1="$(session_hash '/home/u/dev/project a')"
h2="$(session_hash '/home/u/dev/project a')"
assert_eq "session_hash is deterministic" "$h1" "$h2"
assert_eq "session_hash is 8 chars" "${#h1}" "8"
h3="$(session_hash 'other')"
assert_not_contains "session_hash differs per input" "$h1" "$h3"

tmux_set_sessions "pi-abc12345"
name="$(managed_session_name '/x')"
assert_contains "managed name uses prefix" "$name" "pi-"
base="pi-$(session_hash '/x')"
name2="$(managed_session_name '/x' "$base")"
assert_eq "collision gets -2 suffix" "$name2" "${base}-2"
name3="$(managed_session_name '/x' "$base" "${base}-2")"
assert_eq "second collision gets -3 suffix" "$name3" "${base}-3"

is_managed_session "pi-deadbeef" && t_ok "prefix heuristic: managed" || t_fail "prefix heuristic: managed" "expected 0"
is_managed_session "work" && t_fail "prefix heuristic: non-managed" "expected 1" || t_ok "prefix heuristic: non-managed"

t_section "tty decode"
assert_eq "pts/6" "$(tty_nr_to_pts 34822)" "pts/6"
assert_eq "pts/8" "$(tty_nr_to_pts 34824)" "pts/8"
assert_eq "tty1 (major 4)" "$(tty_nr_to_pts 1025)" "tty1"
assert_eq "no tty" "$(tty_nr_to_pts 0)" ""
assert_eq "garbage" "$(tty_nr_to_pts 'abc')" ""
assert_eq "empty" "$(tty_nr_to_pts '')" ""

t_section "time formatting"
assert_eq "fmt_age empty" "$(fmt_age '')" "-"
assert_eq "fmt_age 0" "$(fmt_age 0)" "0s"
assert_eq "fmt_age seconds" "$(fmt_age 45)" "45s"
assert_eq "fmt_age minutes" "$(fmt_age 90)" "1m"
assert_eq "fmt_age hours" "$(fmt_age 7200)" "2h"

t_section "path display"
assert_eq "display_path home" "$(HOME=/home/u display_path '/home/u/dev')" "~/dev"
assert_eq "display_path exact home" "$(HOME=/home/u display_path '/home/u')" "~"
assert_eq "display_path outside" "$(HOME=/home/u display_path '/opt/x')" "/opt/x"

t_section "project naming"
assert_eq "project_name with session name" "$(project_name '/a/b' 'proj')" "proj"
assert_eq "project_name fallback basename" "$(project_name '/a/b' '')" "b"
assert_eq "project_name root" "$(project_name '/' '')" "/"

t_section "config file"
cfg="$(psm_config_file)"
assert_eq "config path resolves into config dir" "$cfg" "$PSM_CONFIG_DIR/config.json"
assert_eq "psm_config_get default" "$(psm_config_get notify_on_waiting 'true')" "true"
mkdir -p "$PSM_CONFIG_DIR"
printf '{"notify_on_waiting":false}\n' > "$cfg"
assert_eq "psm_config_get from file" "$(psm_config_get notify_on_waiting 'true')" "false"
assert_eq "psm_config_get missing key default" "$(psm_config_get nope 'dflt')" "dflt"

t_section "atomic json write"
f="$SB/out.json"
psm_write_json "$f" '{"a":1}'
assert_file "psm_write_json writes file" "$f"
assert_eq "content" "$(cat "$f")" '{"a":1}'
assert_eq "no temp left" "$(ls "$SB" | grep -c 'tmp')" "0"
assert_eq "mode 0600" "$(stat -c %a "$f")" "600"

t_section "process helpers (fake /proc)"
make_proc_pid 101 pi 34822 5000 /usr/bin/node "$SB/projA"
make_proc_pid 102 bash 34824 6000 /usr/bin/bash "$SB/projB"
make_proc_pid 103 node 34826 7000 /usr/bin/node "$SB/projC"
make_proc_pid 104 pi 0 8000 /usr/bin/bun "$SB/projD"

pid_is_pi 101 && t_ok "pi+node is pi" || t_fail "pi+node is pi" "expected true"
pid_is_pi 102 && t_fail "bash+node is not pi" "expected false" || t_ok "bash+node is not pi"
pid_is_pi 103 && t_fail "node+node is not pi (comm mismatch)" "expected false" || t_ok "node+node is not pi (comm mismatch)"
pid_is_pi 104 && t_ok "pi+bun is pi" || t_fail "pi+bun is pi" "expected true"
pid_is_pi 999 && t_fail "missing pid is not pi" "expected false" || t_ok "missing pid is not pi"

PSM_PROCESS_NAMES="pi rebranded"
make_proc_pid 105 rebranded 34828 9000 /usr/bin/node "$SB/projE"
pid_is_pi 105 && t_ok "PSM_PROCESS_NAMES override" || t_fail "PSM_PROCESS_NAMES override" "expected true"
unset PSM_PROCESS_NAMES

assert_eq "pid_comm" "$(pid_comm 101)" "pi"
assert_eq "pid_cmdline_first" "$(pid_cmdline_first 101)" "pi"
assert_eq "pid_exe_name" "$(pid_exe_name 101)" "node"
assert_eq "pid_cwd" "$(pid_cwd 101)" "$SB/projA"
assert_eq "pid_tty_pts" "$(pid_tty_pts 101)" "pts/6"
assert_eq "pid_tty_pts none" "$(pid_tty_pts 104)" ""
assert_eq "pid_start_epoch" "$(pid_start_epoch 101)" "$((1700000000 + 5000 / 100))"
pid_alive 101 && t_ok "pid_alive present" || t_fail "pid_alive present" "expected alive"
make_proc_gone 101
pid_alive 101 && t_fail "pid_alive gone" "expected dead" || t_ok "pid_alive gone"

# --- summary (consumed by run.sh) ---
mkdir -p "$TEST_ROOT/results"
printf '%s %s\n' "$PASS" "$FAIL" > "$TEST_ROOT/results/$SUITE_NAME"
