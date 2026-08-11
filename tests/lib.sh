#!/usr/bin/env bash
# Test framework + sandbox for tmux-pi-session-manager.
#
# Every test runs in a fresh sandbox: fake HOME/XDG dirs, fake /proc tree
# (PSM_PROC_DIR), mocked tmux / pi / notify-send / kill binaries on PATH.
# Real jq / md5sum / stat are used (they are stable on the target platform).
set -u

# --- globals ----------------------------------------------------------------
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="${TEST_ROOT:-/tmp/psm-tests}"
SUITE_NAME=""
PASS=0
FAIL=0
FAILED_TESTS=()

# --- output ----------------------------------------------------------------
t_section() { printf '\n== %s ==\n' "$1"; }

t_ok()   { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
t_fail() {
  FAIL=$((FAIL + 1))
  FAILED_TESTS+=("$SUITE_NAME :: $1")
  printf '  FAIL %s\n' "$1"
  [ -n "${2:-}" ] && printf '       %s\n' "$2"
}

# assert_eq <desc> <actual> <expected>
assert_eq() {
  local desc="$1" actual="$2" expected="$3"
  if [ "$actual" = "$expected" ]; then
    t_ok "$desc"
  else
    t_fail "$desc" "expected [$expected] got [$actual]"
  fi
}

# assert_contains <desc> <haystack> <needle>
assert_contains() {
  local desc="$1" hay="$2" needle="$3"
  case "$hay" in
    *"$needle"*) t_ok "$desc" ;;
    *) t_fail "$desc" "missing [$needle] in [$hay]" ;;
  esac
}

# assert_not_contains <desc> <haystack> <needle>
assert_not_contains() {
  local desc="$1" hay="$2" needle="$3"
  case "$hay" in
    *"$needle"*) t_fail "$desc" "unexpected [$needle] in [$hay]" ;;
    *) t_ok "$desc" ;;
  esac
}

# assert_file <desc> <path>
assert_file() {
  if [ -f "$2" ]; then t_ok "$1"; else t_fail "$1" "missing file $2"; fi
}

# assert_no_file <desc> <path>
assert_no_file() {
  if [ ! -e "$2" ]; then t_ok "$1"; else t_fail "$1" "unexpected file $2"; fi
}

# --- sandbox ----------------------------------------------------------------
# make_sandbox — fresh HOME, fake /proc, state/config dirs, mock PATH.
# Sets: SB (sandbox root), PSM_PROC_DIR, PSM_STATE_DIR, PSM_CONFIG_DIR, HOME,
#       PATH (mocks first), XDG_STATE_HOME/XDG_CONFIG_HOME (unset for determinism).
make_sandbox() {
  SB="$(mktemp -d "$TEST_ROOT/sb.XXXXXX")"
  mkdir -p "$SB/home" "$SB/proc" "$SB/state" "$SB/config" "$SB/bin"
  export SB
  export HOME="$SB/home"
  export PSM_PROC_DIR="$SB/proc"
  export PSM_STATE_DIR="$SB/state"
  export PSM_CONFIG_DIR="$SB/config"
  unset XDG_STATE_HOME XDG_CONFIG_HOME PI_CODING_AGENT_DIR PSM_TMUX 2>/dev/null || true
  export PATH="$SB/bin:$PATH"
  export PSM_TMUX_LOG="$SB/tmux.log"
  export PSM_NOTIFY_LOG="$SB/notify.log"
  export PSM_KILL_LOG="$SB/kill.log"
  export PSM_TMUX_PANES="$SB/panes.tsv"
  export PSM_TMUX_SESSIONS="$SB/sessions.tsv"
  export PSM_TMUX_OPTS="$SB/opts.tsv"
  export PSM_TMUX_MARKERS="$SB/markers.tsv"
  export PSM_TMUX_DISPLAY="$SB/display.txt"
  export PSM_BELL_DEV="$SB/bell.log"
  # Deterministic HOME-based resolution for the launcher's ensure_extension.
  export PI_CODING_AGENT_DIR="$SB/pi-agent"
  mkdir -p "$SB/pi-agent/extensions" "$SB/pi-agent/sessions"
  # /proc/stat with btime for pid_start_epoch.
  printf 'btime 1700000000\n' > "$SB/proc/stat"
}

# make_proc_pid <pid> <comm> <tty_nr> <start_ticks> <exe-symlink-target> [cwd]
# Builds a fake /proc/<pid> entry that the helpers understand.
make_proc_pid() {
  local pid="$1" comm="$2" tty_nr="$3" start="$4" exe="$5" cwd="${6:-}"
  local d="$PSM_PROC_DIR/$pid"
  mkdir -p "$d"
  printf '%s\n' "$comm" > "$d/comm"
  printf '%s\0' "$comm" > "$d/cmdline"
  ln -sfn "$exe" "$d/exe"
  # 1 pid, 2 (comm), 3 state, 4 ppid, 5 pgrp, 6 session, 7 tty_nr, …, 22 starttime
  printf '%s (%s) S 4 5 6 %s 8 9 10 11 12 13 14 15 16 17 18 19 20 21 %s\n' \
    "$pid" "$comm" "$tty_nr" "$start" > "$d/stat"
  if [ -n "$cwd" ]; then
    mkdir -p "$cwd"
    ln -sfn "$cwd" "$d/cwd"
  fi
}

# make_proc_gone <pid> — mark a process as dead (no /proc entry).
make_proc_gone() { rm -rf "$PSM_PROC_DIR/$1"; }

# write_state <session-id> <json> — write an agent state file in the sandbox.
write_state() {
  mkdir -p "$(psm_state_dir)/agents"
  printf '%s\n' "$2" > "$(psm_state_dir)/agents/$1.json"
}

# --- mocks ------------------------------------------------------------------
install_mocks() {
  # Mock tmux — canned responses + call log.
  cat > "$SB/bin/tmux" <<'EOF'
#!/bin/bash
# mock tmux: log everything; answer known queries from scenario files.
printf 'tmux %s\n' "$*" >> "$PSM_TMUX_LOG"
if [ "$1" = "list-panes" ] && [ "$2" = "-a" ]; then
  # race hook: discovery has started — simulate the process dying between the
  # /proc scan and kill's re-verification (kill.sh must refuse to signal it)
  if [ -n "${PSM_TMUX_RACE_SESSION:-}" ] && grep -q "${PSM_TMUX_RACE_SESSION}" "$PSM_TMUX_PANES" 2>/dev/null; then
    rm -rf "$PSM_PROC_DIR/${PSM_TMUX_RACE_PID:-}"
  fi
  # Real tmux resolves #{@pi_tmux_managed} per session; emulate that by
  # appending the session's marker from markers.tsv as a 5th column.
  awk -F'\t' '
    { if (FILENAME == ARGV[1]) { if ($2 == "@pi_tmux_managed") m[$1] = $3; next }
      print $0 "\t" (($3 in m) ? m[$3] : "") }
  ' "$PSM_TMUX_MARKERS" "$PSM_TMUX_PANES" 2>/dev/null
elif [ "$1" = "list-sessions" ] && [ "$2" = "-F" ]; then
  cat "$PSM_TMUX_SESSIONS" 2>/dev/null
elif [ "$1" = "display-message" ] && [ "$2" = "-p" ]; then
  cat "$PSM_TMUX_DISPLAY" 2>/dev/null
elif [ "$1" = "show-option" ] && [ "$2" = "-gqv" ]; then
  awk -F'\t' -v o="$3" '$1 == o { print $2 }' "$PSM_TMUX_OPTS" 2>/dev/null
elif [ "$1" = "show-options" ] && [ "$2" = "-t" ] && [ "$4" = "-v" ]; then
  # show-options -t <sess> -v <opt>
  awk -F'\t' -v s="$3" -v o="$5" '$1 == s && $2 == o { print $3 }' "$PSM_TMUX_MARKERS" 2>/dev/null
  # race hook: when the *target session* is queried, simulate the process
  # dying mid-discovery (kill.sh must re-verify before signalling)
  if [ "${PSM_TMUX_RACE_SESSION:-}" = "$3" ]; then
    rm -rf "$PSM_PROC_DIR/${PSM_TMUX_RACE_PID:-}"
  fi
fi
exit 0
EOF
  # Mock pi.
  printf '#!/bin/bash\nprintf "mock pi %%s\\n" "$*" >> "$SB/pi.log"\nexit 0\n' > "$SB/bin/pi"
  # Mock notify-send — record args.
  cat > "$SB/bin/notify-send" <<'EOF'
#!/bin/bash
printf 'notify-send %s\n' "$*" >> "$PSM_NOTIFY_LOG"
EOF
  # Mock external kill — record signals; optionally "kill" the process by
  # removing its fake /proc entry when PSM_KILL_REALLY_DIES=1.
  cat > "$SB/bin/kill" <<'EOF'
#!/bin/bash
printf 'kill %s\n' "$*" >> "$PSM_KILL_LOG"
sig="${1#-}"
pid="$2"
if [ "${PSM_KILL_REALLY_DIES:-0}" = "1" ] && [ "$sig" = "TERM" ]; then
  rm -rf "$PSM_PROC_DIR/$pid"
fi
exit 0
EOF
  chmod +x "$SB/bin/tmux" "$SB/bin/pi" "$SB/bin/notify-send" "$SB/bin/kill"
  # Default scenario: no panes, no sessions, no options, no markers.
  : > "$PSM_TMUX_PANES"
  : > "$PSM_TMUX_SESSIONS"
  : > "$PSM_TMUX_OPTS"
  : > "$PSM_TMUX_MARKERS"
  printf '\n' > "$PSM_TMUX_DISPLAY"
}

# tmux_set_panes <tsv-lines...> — pane map: tty\tpane\tsession\tloc (dev-less tty)
tmux_set_panes() { printf '%s\n' "$@" > "$PSM_TMUX_PANES"; }

# tmux_set_sessions <names...>
tmux_set_sessions() { printf '%s\n' "$@" > "$PSM_TMUX_SESSIONS"; }

# tmux_set_opt <name> <value>
tmux_set_opt() { printf '%s\t%s\n' "$1" "$2" >> "$PSM_TMUX_OPTS"; }

# tmux_set_marker <session> <option> <value>
tmux_set_marker() { printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$PSM_TMUX_MARKERS"; }

# tmux_set_display <value> — answer for `display-message -p ...`.
tmux_set_display() { printf '%s\n' "$1" > "$PSM_TMUX_DISPLAY"; }

# tmux_log — the recorded tmux invocations.
tmux_log() { cat "$PSM_TMUX_LOG" 2>/dev/null; }
