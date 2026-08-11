#!/usr/bin/env bash
# Interactive fzf picker for running Pi agents.
#
#   picker.sh          fzf picker; on enter, jumps to the chosen agent.
#   picker.sh --list   print the rows only (used by reload bindings).
#
# Rows come from agents.sh. Two kinds of row jump differently:
#   dedicated  an agent in a `pi-*` session this plugin launched — resumed in
#              the popup, over the window it was launched from.
#   loose      an agent in any other pane — focused in place.
#
# Live refresh: when fzf supports --listen, a small background loop re-posts
# the agent list every @pi_tmux_picker_refresh seconds through fzf's HTTP API
# (reload action, /dev/tcp — no curl needed). Working agents get an animated
# spinner dot; rows stay rank-sorted and deduplicated (each reload replaces
# the list). Older fzf versions fall back to a static list.
set -uo pipefail
DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=helpers.sh
. "$DIR/helpers.sh"

PSM_TMUX="${PSM_TMUX:-tmux}"

[ "${1:-}" = '--list' ] && exec "$DIR/agents.sh"

for tool in fzf jq; do
  command -v "$tool" >/dev/null 2>&1 || {
    printf 'tmux-pi-session-manager: %s is required for the picker\n' "$tool" >&2
    exit 1
  }
done

export FZF_DEFAULT_OPTS=''
export PI_TMUX_PICKER="$DIR/picker.sh"

# User-supplied fzf options, split safely (no eval).
extra_opts=()
fzf_options="$(get_tmux_option @pi_tmux_fzf_options '')"
if [ -n "$fzf_options" ]; then
  # Intentional word splitting of user-supplied fzf options (no eval).
  # shellcheck disable=SC2206
  extra_opts=($fzf_options)
fi

preview_lines="$(get_tmux_option @pi_tmux_preview_lines '5')"
kill_confirm="$(get_tmux_option @pi_tmux_kill_confirm 'on')"
picker_refresh="$(get_tmux_option @pi_tmux_picker_refresh '0.12')"

# ctrl-x: confirm-kill the highlighted agent. No reload needed — the live
# loop refreshes the list on its own.
if [ "$kill_confirm" = "on" ]; then
  kill_bind="ctrl-x:execute($DIR/kill.sh {3})"
else
  kill_bind="ctrl-x:execute($DIR/kill.sh --yes {3})"
fi

# Finite preview command: fzf re-runs it whenever the list reloads, so the
# pane preview refreshes automatically with the live loop. (A `while true`
# preview would keep streaming across reloads and pollute the item list.)
preview_cmd="$PSM_TMUX capture-pane -ept {2} -S -${preview_lines} 2>/dev/null"

# Does this fzf support --listen (live updates)? fzf >= 0.42-ish.
if fzf --help 2>&1 | grep -q -- '--listen'; then
  live=1
else
  live=0
fi

# Animated spinner for WORKING rows (10 frames). The frame char is swapped
# into the cached agents.sh output between full refreshes, so the dot spins
# fast without re-running discovery every frame.
SPINNER_CHARS='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
SPINNER_NFRAMES=${#SPINNER_CHARS}

fzf_args=(--ansi --delimiter=$'\t' --with-nth=7,8,9,10,11 \
  --reverse --cycle --no-sort \
  --header='Pi agents · enter: jump · ctrl-x: kill · q: quit' \
  --preview="$preview_cmd" \
  --preview-window="up,65%" \
  --bind="$kill_bind")

live_tmp=""
TIMER_PID=""
if [ "$live" -eq 1 ]; then
  live_tmp="$(mktemp -d)"
  portfile="$live_tmp/port"
  rowsfile="$live_tmp/rows.tsv"
  fzf_args+=(--listen --bind="start:execute-silent:echo \$FZF_PORT > $portfile")
  # Live refresh loop: full discovery every 4th tick, spinner frames on the
  # ticks in between. Posts reload(cat rowsfile) through fzf's HTTP API over
  # /dev/tcp (no curl needed). Runs in the background WHILE fzf is up.
  (
    port=""
    for _ in $(seq 1 60); do
      [ -f "$portfile" ] && port="$(cat "$portfile" 2>/dev/null)" && [ -n "$port" ] && break
      sleep 0.1
    done
    [ -n "$port" ] || exit 0
    frame=0
    rows=""
    while true; do
      if [ $((frame % 4)) -eq 0 ]; then
        rows="$("$DIR/agents.sh" 2>/dev/null)"
      fi
      c="${SPINNER_CHARS:$((frame % SPINNER_NFRAMES)):1}"
      printf '%s\n' "$rows" | awk -v f="$c" 'index($0, "WORKING") { sub("●", f) } { print }' > "$rowsfile"
      body="reload(cat '$rowsfile')"
      # /dev/tcp POST (no curl): content-length must be byte-exact.
      exec 3<>"/dev/tcp/127.0.0.1/$port" 2>/dev/null && {
        printf 'POST / HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: %s\r\nConnection: close\r\n\r\n%s' \
          "${#body}" "$body" >&3
        exec 3>&-
      }
      frame=$((frame + 1))
      sleep "$picker_refresh"
    done
  ) &
  TIMER_PID=$!
fi

sel="$("$DIR/agents.sh" 2>/dev/null | fzf "${fzf_args[@]}" ${extra_opts[@]+"${extra_opts[@]}"})"

# fzf has exited: stop the refresh loop and clean up.
[ -n "$TIMER_PID" ] && kill "$TIMER_PID" 2>/dev/null
[ -n "$live_tmp" ] && rm -rf "$live_tmp"

[ -z "$sel" ] && exit 0
pane=$(printf '%s' "$sel" | cut -f2)
kind=$(printf '%s' "$sel" | cut -f4)

parent=$(get_tmux_option @pi_tmux_parent '')
session=$("$PSM_TMUX" display-message -p -t "$pane" '#{session_name}' 2>/dev/null)
[ -n "$session" ] || exit 0

if [ "$kind" = loose ]; then
  # Focus the pane in place on the host client. This popup closes on its own
  # when the script exits.
  if [ -n "$parent" ]; then
    "$PSM_TMUX" switch-client -c "$parent" -t "$session" 2>/dev/null
  else
    "$PSM_TMUX" switch-client -t "$session" 2>/dev/null
  fi
  "$PSM_TMUX" select-window -t "$pane" 2>/dev/null
  "$PSM_TMUX" select-pane -t "$pane" 2>/dev/null
  exit 0
fi

# Dedicated: move the host client to the window the session was launched from
# (best-effort), focus the chosen agent's window inside the session, then
# resume the agent in THIS popup over the top.
origin=$("$PSM_TMUX" show-options -qv -t "$session" @pi_tmux_origin 2>/dev/null)
if [ -n "$origin" ] && [ -n "$parent" ]; then
  "$PSM_TMUX" switch-client -c "$parent" -t "$origin" 2>/dev/null
fi
"$PSM_TMUX" select-window -t "$pane" 2>/dev/null
"$PSM_TMUX" select-pane -t "$pane" 2>/dev/null
exec "$PSM_TMUX" attach-session -t "$session"
