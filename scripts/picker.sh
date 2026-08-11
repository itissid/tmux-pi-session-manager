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

preview_refresh="$(get_tmux_option @pi_tmux_preview_refresh '1')"
preview_lines="$(get_tmux_option @pi_tmux_preview_lines '5')"
kill_confirm="$(get_tmux_option @pi_tmux_kill_confirm 'on')"

# ctrl-x: confirm-kill the highlighted agent, then reload.
if [ "$kill_confirm" = "on" ]; then
  kill_bind="ctrl-x:execute($DIR/kill.sh {3})+reload($DIR/picker.sh --list)"
else
  kill_bind="ctrl-x:execute($DIR/kill.sh --yes {3})+reload($DIR/picker.sh --list)"
fi

preview_cmd="while true; do $PSM_TMUX capture-pane -ept {2} -S -${preview_lines} 2>/dev/null; sleep ${preview_refresh}; done"

sel=$("$DIR/agents.sh" | fzf --ansi --delimiter=$'\t' --with-nth=7,8,9,10,11 \
  --reverse --cycle \
  --header='Pi agents · enter: jump · ctrl-x: kill · R: reload · q: quit' \
  --preview="$preview_cmd" \
  --preview-window="up,65%" \
  --bind="R:reload($DIR/picker.sh --list)" \
  --bind="$kill_bind" \
  ${extra_opts[@]+"${extra_opts[@]}"})

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
