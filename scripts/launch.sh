#!/usr/bin/env bash
# Launch a Pi agent for a directory in a new dedicated tmux session, or resume
# a previous Pi session by its session id.
#
# usage: launch.sh [--dir DIR] [--name NAME] [--resume SESSION_ID] [--window WID] [-- args...]
#
# Every launch creates a *distinct* tmux session (pi-<hash8>[-<n>]) so multiple
# agents per directory are first-class. The window runs `pi [args]` (or
# `pi --session <file>` for resume). The user is attached in a popup when the
# command runs inside tmux, or with a plain attach otherwise.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=helpers.sh
. "$DIR/helpers.sh"

PSM_TMUX="${PSM_TMUX:-tmux}"

# ensure_extension — copy the bundled extension into pi's extensions dir when
# missing (auto-install keeps discovery/status working for launched agents).
# Opt out with @pi_tmux_auto_install_extension off.
ensure_extension() {
  local ext_dir ext_file bundled
  [ "$(get_tmux_option @pi_tmux_auto_install_extension 'on')" = "on" ] || return 0
  ext_dir="$(pi_extensions_dir)"
  ext_file="$ext_dir/pi-tmux-session-manager.ts"
  bundled="$DIR/../pi/extension.ts"
  [ -f "$bundled" ] || return 0
  if [ ! -f "$ext_file" ]; then
    mkdir -p "$ext_dir"
    if cp "$bundled" "$ext_file" 2>/dev/null; then
      printf 'pi-tmux: installed pi extension at %s (reload pi with /reload to activate)\n' "$ext_file" >&2
    else
      printf 'pi-tmux: could not install extension at %s — run `pi-tmux install-extension`\n' "$ext_file" >&2
    fi
  fi
}

main() {
  local dir="" name="" resume="" window="" attach=1 cmd explicit_dir=0
  local extra_args=()
  local -a args=("$@")

  while [ "${#args[@]}" -gt 0 ]; do
    case "${args[0]}" in
      --dir) dir="${args[1]}"; explicit_dir=1; args=("${args[@]:2}") ;;
      --name) name="${args[1]}"; args=("${args[@]:2}") ;;
      --resume) resume="${args[1]}"; args=("${args[@]:2}") ;;
      --window) window="${args[1]}"; args=("${args[@]:2}") ;;
      --no-attach) attach=0; args=("${args[@]:1}") ;;
      --) extra_args=("${args[@]:1}"); args=() ;;
      -*) printf 'pi-tmux: unknown option %s\n' "${args[0]}" >&2; exit 2 ;;
      *) extra_args=("${args[@]}"); args=() ;;
    esac
  done

  [ -n "$dir" ] || dir="${PWD:-$(pwd)}"
  dir="$(readlink -f "$dir" 2>/dev/null || printf '%s' "$dir")"
  [ -d "$dir" ] || { printf 'pi-tmux: directory does not exist: %s\n' "$dir" >&2; exit 1; }

  # Never nest a dedicated session inside another one.
  local cur_session
  cur_session="$("$PSM_TMUX" display-message -p '#S' 2>/dev/null)"
  if [ -n "$cur_session" ] && tmux_session_managed "$cur_session" 2>/dev/null; then
    "$PSM_TMUX" display-message 'pi-tmux: already inside a pi agent session — use the picker to switch' 2>/dev/null
    printf 'pi-tmux: already inside a pi agent session\n' >&2
    exit 1
  fi

  # Build the command.
  local pi_cmd
  pi_cmd="$(get_tmux_option @pi_tmux_command 'pi')"
  if [ -n "$resume" ]; then
    local sfile sfile_cwd
    sfile="$(find_session_file "$resume")"
    [ -n "$sfile" ] || { printf 'pi-tmux: no session found for id %s\n' "$resume" >&2; exit 1; }
    cmd=("$pi_cmd" --session "$sfile")
    # Resume into the project directory the original session ran in (unless
    # the caller passed an explicit --dir).
    sfile_cwd="$(head -n1 "$sfile" 2>/dev/null | jq -r '.cwd // empty' 2>/dev/null)"
    if [ "$explicit_dir" -eq 0 ] && [ -n "$sfile_cwd" ] && [ -d "$sfile_cwd" ]; then
      dir="$sfile_cwd"
    fi
    printf 'pi-tmux: resuming session %s\n' "$sfile" >&2
  else
    cmd=("$pi_cmd")
  fi
  local pi_args
  pi_args="$(get_tmux_option @pi_tmux_args '')"
  if [ -n "$pi_args" ]; then
    # shellcheck disable=SC2206
    cmd+=($pi_args)
  fi
  cmd+=("${extra_args[@]}")
  [ -z "$name" ] || cmd+=(--name "$name")

  ensure_extension

  # Unique session name.
  local taken=()
  while IFS= read -r s; do taken+=("$s"); done < <("$PSM_TMUX" list-sessions -F '#{session_name}' 2>/dev/null)
  local session
  session="$(managed_session_name "$dir" "${taken[@]}")"

  # Explicit env overrides are injected into the command itself (`env VAR=x …`)
  # because tmux spawns the first command with the *server's* process environ;
  # session/global env overrides of existing vars are not reliable across tmux
  # builds. This keeps `pi-tmux launch` deterministic in any environment.
  local envvar env_prefix=()
  for envvar in PSM_STATE_DIR PSM_CONFIG_DIR PSM_PROCESS_NAMES PSM_NOTIFY_SEND \
                PI_CODING_AGENT_DIR PI_CONFIG_DIR; do
    [ -n "${!envvar:-}" ] && env_prefix+=(env "$envvar=${!envvar}")
  done

  "$PSM_TMUX" new-session -d -s "$session" -c "$dir" -- "${env_prefix[@]}" "${cmd[@]}"
  "$PSM_TMUX" set-option -t "$session" @pi_tmux_managed 1
  [ -n "$window" ] && "$PSM_TMUX" set-option -t "$session" @pi_tmux_origin "$window"

  printf 'pi-tmux: launched pi agent in session %s (%s)\n' "$session" "$dir" >&2

  # Attach: popup from inside tmux, plain attach otherwise.
  local w h
  w="$(get_tmux_option @pi_tmux_popup_width '90%')"
  h="$(get_tmux_option @pi_tmux_popup_height '90%')"
  if [ "$attach" -eq 1 ] && [ -n "${TMUX:-}" ]; then
    "$PSM_TMUX" display-popup -w "$w" -h "$h" -E "$PSM_TMUX attach-session -t '$session'"
  elif [ "$attach" -eq 1 ]; then
    exec "$PSM_TMUX" attach-session -t "$session"
  fi
}

# find_session_file <id|path> — locate a pi session file by id or direct path.
find_session_file() {
  local id="$1" root f
  case "$id" in
    */*) [ -f "$id" ] && { printf '%s' "$id"; return; } ;;
  esac
  root="$(pi_sessions_dir)"
  [ -d "$root" ] || return 1
  for f in "$root"/*/*.jsonl; do
    [ -f "$f" ] || continue
    case "$f" in
      *_"$id".jsonl) printf '%s' "$f"; return ;;
    esac
  done
  return 1
}

main "$@"
