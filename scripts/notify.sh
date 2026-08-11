#!/usr/bin/env bash
# Notification engine (bash side).
#
# The Pi extension sends notifications in-process on status transitions. This
# script provides the same logic for:
#   * `pi-tmux notify`            — one-shot reconcile (also cleans stale state)
#   * `pi-tmux notify --watch`    — optional poller for agents that died
#                                   unexpectedly (opt-in; no daemon by default)
#
# Dedup contract (shared with the extension): a notification fires only when
# the agent's status *changes* (waiting/error). WAITING → WAITING sends
# nothing; WAITING → WORKING → WAITING sends again.
set -uo pipefail
DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=helpers.sh
. "$DIR/helpers.sh"

# notify_id <session-id> — stable numeric id for notify-send -r (replacement).
notify_id() {
  local h=0 i c
  for ((i = 0; i < ${#1}; i++)); do
    c=$(printf '%d' "'${1:i:1}")
    h=$(( (h * 31 + c) & 0x7fffffff ))
  done
  [ "$h" -gt 0 ] || h=1
  printf '%s' "$h"
}

# send_notification <kind> <state-file> — fire notify-send for one agent.
send_notification() {
  local kind="$1" file="$2" backend title body icon sid cwd sname project loc
  backend="$(psm_config_get notification_backend 'auto')"
  [ "$backend" = "off" ] && return 0
  command -v notify-send >/dev/null 2>&1 || return 0
  sid="$(basename "$file" .json)"
  cwd="$(jq -r '.cwd // ""' "$file")"
  sname="$(jq -r '.session_name // ""' "$file")"
  project="$(project_name "$cwd" "$sname")"
  loc="$(jq -r 'if .tmux_loc != null then .tmux_loc else "" end' "$file" 2>/dev/null)"
  [ -n "$loc" ] || loc="tmux"
  case "$kind" in
    error)
      title="Pi agent error"; icon="dialog-error"
      body="$(printf '%s · %s\n%s\nThe agent encountered an error and needs your attention.' "$project" "$loc" "$cwd")" ;;
    done)
      title="Pi agent completed"; icon="dialog-information"
      body="$(printf '%s · %s\n%s\nThe current task has completed.' "$project" "$loc" "$cwd")" ;;
    waiting)
      title="Pi agent waiting for input"; icon="dialog-warning"
      body="$(printf '%s · %s\n%s\nPi finished a task and is waiting for your input.' "$project" "$loc" "$cwd")" ;;
    blocked)
      title="Pi agent needs your attention"; icon="dialog-question"
      body="$(printf '%s · %s\n%s\nThe agent is waiting for your input (a question or a permission request).' "$project" "$loc" "$cwd")" ;;
    exited)
      title="Pi agent stopped unexpectedly"; icon="dialog-error"
      body="$(printf '%s · %s\n%s\nThe agent process died while it was working.' "$project" "$loc" "$cwd")" ;;
  esac
  notify-send -a pi -i "$icon" -r "$(notify_id "$sid")" -t 10000 "$title" "$body" 2>/dev/null
}

# mark_notified <file> <status> — record the dedup marker in the state file.
mark_notified() {
  local file="$1" status="$2" ts tmp
  ts="$(date +%s)000"
  tmp="$file.tmp.$$"
  jq --arg st "$status" --argjson ts "$ts" '.notify = {last_sent_status: $st, last_sent_at: $ts}' "$file" > "$tmp" 2>/dev/null && mv -f "$tmp" "$file"
  rm -f "$tmp"
}

# reconcile_one <file> — evaluate a single state file; returns 0 when a
# notification was sent. Mirrors the extension's transition logic.
reconcile_one() {
  local file="$1" pid status last_stop cwd sname started
  local input_at notify_last cfg_waiting cfg_error cfg_done cfg_blocked cfg_min
  local kind

  pid="$(jq -r '.pid // empty' "$file" 2>/dev/null)"
  if [ -z "$pid" ] || ! pid_alive "$pid" || ! pid_is_pi "$pid"; then
    rm -f "$file"      # stale state
    return 1
  fi

  status="$(jq -r '.status // "idle"' "$file")"
  notify_last="$(jq -r '.notify.last_sent_status // ""' "$file")"
  [ "$status" = "$notify_last" ] && return 1

  # Agent died while working and the extension never marked it exited.
  alive="$(jq -r '.alive // true' "$file")"
  if [ "$alive" = "true" ] && [ "$status" = "working" ]; then
    # process is still alive here (checked above) — only meaningful for watch
    :
  fi

  case "$status" in
    blocked)
      cfg_blocked="$(psm_config_get notify_on_blocked 'true')"
      [ "$cfg_blocked" = "true" ] || return 1
      send_notification blocked "$file"
      mark_notified "$file" "blocked"
      return 0
      ;;
    waiting)
      cfg_waiting="$(psm_config_get notify_on_waiting 'true')"
      cfg_done="$(psm_config_get notify_on_done 'false')"
      [ "$cfg_waiting" = "true" ] || [ "$cfg_done" = "true" ] || return 1
      input_at="$(jq -r '.last_user_input_at // .started_at // 0' "$file")"
      started="$(jq -r '.started_at // 0' "$file")"
      cfg_min="$(psm_config_get min_attention_duration_ms '5000')"
      now_ms=$(( $(date +%s) * 1000 ))
      base="$input_at"; [ -n "$base" ] && [ "$base" -gt 0 ] || base="$started"
      duration=$((now_ms - base))
      [ "$duration" -ge "$cfg_min" ] || return 1
      last_stop="$(jq -r '.last_stop_reason // ""' "$file")"
      if [ "$cfg_waiting" = "true" ] && [ "$cfg_done" = "true" ] && [ "$last_stop" = "stop" ]; then
        send_notification "done" "$file"; send_notification waiting "$file"
      elif [ "$cfg_done" = "true" ] && [ "$last_stop" = "stop" ]; then
        send_notification "done" "$file"
      elif [ "$cfg_waiting" = "true" ]; then
        send_notification waiting "$file"
      else
        return 1
      fi
      mark_notified "$file" "waiting"
      return 0
      ;;
    error)
      cfg_error="$(psm_config_get notify_on_error 'true')"
      [ "$cfg_error" = "true" ] || return 1
      send_notification error "$file"
      mark_notified "$file" "error"
      return 0
      ;;
    *)
      # working/idle transitions never notify; reset the dedup marker so the
      # next attention transition fires again (WAITING→WORKING→WAITING).
      if [ -n "$notify_last" ]; then
        mark_notified "$file" ""
      fi
      return 1
      ;;
  esac
}

# reconcile — evaluate every live state file, clean stale ones.
reconcile() {
  local adir f sent=0
  adir="$(psm_agents_dir)"
  [ -d "$adir" ] || return 0
  while IFS= read -r f; do
    reconcile_one "$f" && sent=$((sent + 1))
  done < <(find "$adir" -maxdepth 1 -name '*.json' -type f 2>/dev/null)
  [ "$sent" -gt 0 ] && printf 'pi-tmux: sent %s notification(s)\n' "$sent" >&2
}

# watch — optional poller: reconcile + detect unexpected deaths.
watch() {
  local interval="${PSM_NOTIFY_INTERVAL:-10}" f pid alive status notify_exit last
  notify_exit="$(psm_config_get notify_on_exit 'false')"
  printf 'pi-tmux: watching agent state every %ss (ctrl-c to stop)\n' "$interval" >&2
  while true; do
    reconcile
    if [ "$notify_exit" = "true" ]; then
      local adir
      adir="$(psm_agents_dir)"
      if [ -d "$adir" ]; then
        while IFS= read -r f; do
          pid="$(jq -r '.pid // empty' "$f" 2>/dev/null)"
          [ -n "$pid" ] || continue
          if ! pid_alive "$pid" || ! pid_is_pi "$pid"; then
            alive="$(jq -r '.alive // false' "$f")"
            status="$(jq -r '.status // ""' "$f")"
            last="$(jq -r '.notify.last_sent_status // ""' "$f")"
            if [ "$alive" = "true" ] && [ "$last" != "exited" ] && [ "$status" = "working" ]; then
              send_notification exited "$f"
              mark_notified "$f" "exited"
            fi
            rm -f "$f"
          fi
        done < <(find "$adir" -maxdepth 1 -name '*.json' -type f 2>/dev/null)
      fi
    fi
    sleep "$interval"
  done
}

main() {
  case "${1:-}" in
    --watch) watch ;;
    *) reconcile ;;
  esac
}

main "$@"
