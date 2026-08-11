#!/usr/bin/env bash
# Open the agent picker in a popup.
#
# usage: list.sh [client-name]
#
# Handles two cases:
#   * normal client        — the picker opens in a popup on this client; the
#                            client is recorded as @pi_tmux_parent so jumps
#                            know where to switch back to.
#   * inside a session popup — the popup client is detached (closing the
#                            overlay) and the picker reopens full-size on the
#                            outer host client, never popup-in-popup.
set -uo pipefail
DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=helpers.sh
. "$DIR/helpers.sh"

PSM_TMUX="${PSM_TMUX:-tmux}"

prefix="$(get_tmux_option @pi_tmux_session_prefix 'pi-')"
w="$(get_tmux_option @pi_tmux_popup_width '90%')"
h="$(get_tmux_option @pi_tmux_popup_height '90%')"

# The client that pressed the key, and the session it is currently attached to.
me="${1:-}"
my_session="$("$PSM_TMUX" list-clients -F '#{client_name} #{session_name}' 2>/dev/null |
  awk -v me="$me" '$1 == me { print $2; exit }')"

# open_picker <host> — show the picker popup on <host>, or on the default
# client when <host> is empty. Returns display-popup's own exit status.
open_picker() {
  if [ -n "$1" ]; then
    "$PSM_TMUX" display-popup -c "$1" -w "$w" -h "$h" -E "$DIR/picker.sh"
  else
    "$PSM_TMUX" display-popup -w "$w" -h "$h" -E "$DIR/picker.sh"
  fi
}

case "$my_session" in
"$prefix"*)
  # Inside a session popup: close it, then reopen the picker on the outer client.
  #
  # display-popup returns to its caller *before* tmux finishes destroying the
  # closing overlay, and a popup opened during that window never receives
  # keyboard input. So wait for the popup's client to leave, settle past the
  # teardown, then reopen — retrying a reopen that is rejected mid-teardown.
  "$PSM_TMUX" detach-client -s "$my_session"
  for _ in $(seq 1 100); do
    "$PSM_TMUX" list-clients -F '#{session_name}' 2>/dev/null | grep -qx "$my_session" || break
    sleep 0.05
  done
  host="$("$PSM_TMUX" show-options -gqv @pi_tmux_parent 2>/dev/null)"
  # A stale parent would make every retry fail; fall back to the default client.
  if [ -n "$host" ] && ! "$PSM_TMUX" list-clients -F '#{client_name}' 2>/dev/null | grep -qx "$host"; then
    host=''
  fi

  sleep 0.1
  rc=0
  for _ in $(seq 1 40); do
    before=$SECONDS
    open_picker "$host"
    rc=$?
    { [ "$rc" -eq 0 ] || [ $((SECONDS - before)) -ge 1 ]; } && break
    sleep 0.1
  done
  exit "$rc"
  ;;
*)
  # Normal case: this client is already the host, with no overlay to race.
  host="$me"
  "$PSM_TMUX" set-option -g @pi_tmux_parent "$host"
  ;;
esac

open_picker "$host"
