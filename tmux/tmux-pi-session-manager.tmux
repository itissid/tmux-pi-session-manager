#!/usr/bin/env bash
# tmux-pi-session-manager — tmux plugin entry point.
#
# Installs the key bindings (configurable via tmux options, defaults below):
#
#   set -g @pi_tmux_launch_key 'P'   # prefix + Shift+P: launch pi for cwd
#   set -g @pi_tmux_list_key   'p'   # prefix + p:       open the agent picker
#
# When a key is already bound to a non-default command in your config, the
# plugin leaves your binding alone and prints a hint — set the @pi_tmux_*_key
# option to your preferred key instead.
set -uo pipefail
CURRENT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=../scripts/helpers.sh
. "$CURRENT_DIR/../scripts/helpers.sh"

PSM_TMUX="${PSM_TMUX:-tmux}"

launch_key="$(get_tmux_option @pi_tmux_launch_key 'P')"
list_key="$(get_tmux_option @pi_tmux_list_key 'p')"

# bind_or_warn <key> <command> <desc>
# Bind prefix+<key> to <command> unless the key is already bound to something
# other than tmux's default (previous-window / next-window for p/n, etc.).
bind_or_warn() {
  local key="$1" command="$2" desc="$3" current
  current="$("$PSM_TMUX" list-keys -T prefix "$key" 2>/dev/null | head -n1)"
  if [ -n "$current" ]; then
    case "$current" in
      *previous-window* | *next-window* | *select-window* | *kill-window*)
        # tmux defaults — safe to rebind
        ;;
      *)
        "$PSM_TMUX" display-message "tmux-pi: prefix+$key is already bound — set @pi_tmux_${desc}_key to use this plugin" 2>/dev/null
        return
        ;;
    esac
  fi
  "$PSM_TMUX" bind-key -T prefix "$key" run-shell "$command"
}

# Launch (or resume) a pi session for the current pane's directory.
# #{q:pane_current_path} / #{q:window_id} are expanded by run-shell before the
# args reach the script.
bind_or_warn "$launch_key" \
  "$CURRENT_DIR/../scripts/launch.sh --dir '#{q:pane_current_path}' --window '#{q:window_id}'" \
  "launch"

# Open the agent picker. When pressed from inside a session popup, list.sh
# closes that popup first so the picker opens full-size on the outer client.
bind_or_warn "$list_key" \
  "$CURRENT_DIR/../scripts/list.sh '#{q:client_name}'" \
  "list"
