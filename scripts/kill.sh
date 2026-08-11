#!/usr/bin/env bash
# Safe termination of a Pi agent.
#
# usage: kill.sh <pid|session-id|pane-id> [--yes]
#
# Resolution: the target is matched against the live discovery rows
# (agents.sh) — pid (field 3), session id (field 5), or tmux pane id
# (field 2). The pid is then re-verified against /proc (fingerprint) before
# any signal is sent. Termination is graceful: SIGTERM, then SIGKILL after
# 3s if still alive. State files are removed afterwards.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=helpers.sh
. "$DIR/helpers.sh"

# resolve_row <target> — echo the agents.sh row for the target, or nothing.
resolve_row() {
  local t="$1"
  case "$t" in
    %*)
      awk -F'\t' -v p="$t" '$2 == p { print; exit }' < <("$DIR/agents.sh") ;;
    *-*-*-*-*)
      awk -F'\t' -v s="$t" '$5 == s { print; exit }' < <("$DIR/agents.sh") ;;
    *[!0-9]*|'')
      return 1 ;;
    *)
      awk -F'\t' -v p="$t" '$3 == p { print; exit }' < <("$DIR/agents.sh") ;;
  esac
}

# kill_pid <pid> — SIGTERM, escalate to SIGKILL, verify death. 0 on success.
# Uses `command kill` (external) so tests can intercept; grace is configurable
# (PSM_KILL_GRACE in 0.1s steps, default 30 = 3s).
kill_pid() {
  local pid="$1" i grace
  grace="${PSM_KILL_GRACE:-30}"
  if ! pid_alive "$pid"; then return 0; fi   # already gone
  # `env kill` forces the external kill binary (bash's `kill` builtin would
  # bypass PATH — tests stub it, and semantics are identical in production).
  env kill -TERM "$pid" 2>/dev/null || return 1
  for i in $(seq 1 "$grace"); do
    pid_alive "$pid" || return 0
    sleep 0.1
  done
  env kill -KILL "$pid" 2>/dev/null
  sleep 0.2
  pid_alive "$pid" && return 1
  return 0
}

main() {
  local target="$1" confirm=1 row pid pane sid kind
  shift || true
  for a in "$@"; do
    [ "$a" = "--yes" ] && confirm=0
  done

  row="$(resolve_row "$target")"
  if [ -z "$row" ]; then
    printf 'pi-tmux: no running pi agent matches "%s"\n' "$target" >&2
    exit 1
  fi
  pid="$(printf '%s' "$row" | cut -f3)"
  pane="$(printf '%s' "$row" | cut -f2)"
  sid="$(printf '%s' "$row" | cut -f5)"
  kind="$(printf '%s' "$row" | cut -f4)"

  # Verify before touching anything.
  if [ -z "$pid" ] || ! pid_alive "$pid" || ! pid_is_pi "$pid"; then
    printf 'pi-tmux: refusing to kill %s — not a verified pi process\n' "$pid" >&2
    exit 1
  fi

  if [ "$confirm" -eq 1 ]; then
    local answer
    answer="$(printf 'Yes, kill this agent\nNo, cancel\n' |
      fzf --reverse --no-multi --no-sort \
        --prompt 'Kill this Pi agent? ' \
        --header '↑↓ select · Enter confirm · Esc cancel' 2>/dev/null)"
    case "$answer" in
      Yes*) ;;
      *) printf 'cancelled\n' >&2; exit 1 ;;
    esac
  fi

  psm_debug "killing pi agent pid=$pid pane=$pane sid=$sid kind=$kind"
  if kill_pid "$pid"; then
    printf 'pi-tmux: terminated pi agent (pid %s)\n' "$pid"
  else
    printf 'pi-tmux: failed to terminate pid %s\n' "$pid" >&2
    exit 1
  fi

  # Clean up associated state (real session ids only — pid:<pid> fallback
  # identities never have a state file).
  case "$sid" in
    pid:*) : ;;
    *) rm -f "$(psm_agents_dir)/${sid}.json" ;;
  esac
}

main "$@"
