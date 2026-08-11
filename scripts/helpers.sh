#!/usr/bin/env bash
# Shared helpers for tmux-pi-session-manager.
#
# All paths resolve through the environment so tests can redirect everything:
#   PSM_STATE_DIR   state dir  (default: $XDG_STATE_HOME/pi-tmux-session-manager)
#   PSM_CONFIG_DIR  config dir (default: $XDG_CONFIG_HOME/pi-tmux-session-manager)
#   PSM_PROC_DIR    /proc mount to scan (default: /proc)
#   PSM_TMUX        tmux binary (default: tmux)

# Options (tmux global options with defaults)

# get_tmux_option <option-name> <default>
# Echoes the tmux global option value, or the default when unset/empty.
get_tmux_option() {
  local value
  value="$("${PSM_TMUX:-tmux}" show-option -gqv "$1" 2>/dev/null)"
  if [ -n "$value" ]; then
    printf '%s' "$value"
  else
    printf '%s' "$2"
  fi
}

# Directory resolution

# psm_state_dir — where agents' state files live.
psm_state_dir() {
  if [ -n "${PSM_STATE_DIR:-}" ]; then printf '%s' "$PSM_STATE_DIR"; return; fi
  if [ -n "${XDG_STATE_HOME:-}" ]; then printf '%s' "$XDG_STATE_HOME/pi-tmux-session-manager"; return; fi
  printf '%s' "$HOME/.local/state/pi-tmux-session-manager"
}

# psm_config_dir — where config.json lives.
psm_config_dir() {
  if [ -n "${PSM_CONFIG_DIR:-}" ]; then printf '%s' "$PSM_CONFIG_DIR"; return; fi
  if [ -n "${XDG_CONFIG_HOME:-}" ]; then printf '%s' "$XDG_CONFIG_HOME/pi-tmux-session-manager"; return; fi
  printf '%s' "$HOME/.config/pi-tmux-session-manager"
}

# psm_agents_dir — where the extension writes per-session JSON state.
psm_agents_dir() {
  printf '%s/agents' "$(psm_state_dir)"
}

# psm_config_file — the shared JSON config consumed by extension and manager.
psm_config_file() {
  printf '%s/config.json' "$(psm_config_dir)"
}

# pi_agent_dir — Pi's own agent config directory, resolved exactly the way pi
# resolves it (see pi's config.js): $PI_CODING_AGENT_DIR env first, then
# $HOME/<piConfig.configDir>/agent read from the installed pi package.json,
# then a legacy ~/.pi/agent fallback. Echoes nothing when pi cannot be found.
pi_agent_dir() {
  local pkg_dir cfg pkg_json
  if [ -n "${PI_CODING_AGENT_DIR:-}" ]; then
    printf '%s' "${PI_CODING_AGENT_DIR%/}"
    return
  fi
  pkg_dir="$(pi_package_dir)"
  if [ -n "$pkg_dir" ]; then
    pkg_json="$pkg_dir/package.json"
    if [ -f "$pkg_json" ]; then
      cfg="$(jq -r '.piConfig.configDir // ""' "$pkg_json" 2>/dev/null)"
    fi
    if [ -n "$cfg" ]; then
      printf '%s' "$HOME/$cfg/agent"
      return
    fi
  fi
  if [ -d "$HOME/.pi/agent" ]; then
    printf '%s' "$HOME/.pi/agent"
    return
  fi
  printf '%s' "$HOME/.pi/agent"
}

# pi_package_dir — the installed pi package root (where package.json lives),
# found through the `pi` executable on PATH (symlinks resolved).
pi_package_dir() {
  local bin real pkg
  bin="$(command -v pi 2>/dev/null)" || return 1
  real="$(readlink -f "$bin" 2>/dev/null)" || real="$bin"
  pkg="$(dirname "$(dirname "$real")")"
  [ -f "$pkg/package.json" ] || return 1
  printf '%s' "$pkg"
}

# pi_sessions_dir — where pi stores session JSONL files.
pi_sessions_dir() {
  printf '%s/sessions' "$(pi_agent_dir)"
}

# pi_extensions_dir — where pi auto-loads *.ts extensions from.
pi_extensions_dir() {
  printf '%s/extensions' "$(pi_agent_dir)"
}

# Hashing / naming

# session_hash <string> — short stable 8-char hash (md5, first 8 chars).
session_hash() {
  local out
  out="$(printf '%s\n' "$1" | md5sum 2>/dev/null)"
  out="${out%% *}"
  printf '%s' "${out:0:8}"
}

# managed_session_name <dir> [taken-names...] — a unique dedicated session name
# for launching an agent in <dir>: "pi-<hash8>" or "pi-<hash8>-<n>".
managed_session_name() {
  local dir="$1" prefix base name n
  prefix="$(get_tmux_option @pi_tmux_session_prefix 'pi-')"
  base="${prefix}$(session_hash "$dir")"
  name="$base"
  n=2
  while printf '%s\n' "$@" | grep -qx "$name" 2>/dev/null; do
    name="${base}-${n}"
    n=$((n + 1))
  done
  printf '%s' "$name"
}

# is_managed_session <session-name> — true for sessions created by this plugin
# (name prefix heuristic; the authoritative marker is the tmux option).
is_managed_session() {
  local prefix
  prefix="$(get_tmux_option @pi_tmux_session_prefix 'pi-')"
  case "$1" in
    "$prefix"*) return 0 ;;
    *) return 1 ;;
  esac
}

# tmux_session_managed <session-name> — dedicated sessions carry the launcher
# marker (@pi_tmux_managed); the name-prefix heuristic is the fallback for
# manually-renamed sessions.
tmux_session_managed() {
  local marker
  marker="$("${PSM_TMUX:-tmux}" show-options -t "$1" -v @pi_tmux_managed 2>/dev/null)"
  [ "$marker" = "1" ] && return 0
  is_managed_session "$1"
}

# Time / formatting

# now_epoch — epoch seconds.
now_epoch() { date +%s 2>/dev/null; }

# fmt_age <duration-seconds-or-empty> — "12s", "2m", "14m", "1h", "-".
# The argument is a duration (not an epoch).
fmt_age() {
  local age="$1"
  [ -n "$age" ] || { printf '%s' '-'; return; }
  if [ "$age" -lt 60 ]; then
    printf '%ss' "$age"
  elif [ "$age" -lt 3600 ]; then
    printf '%sm' "$((age / 60))"
  else
    printf '%sh' "$((age / 3600))"
  fi
}

# file_mtime <path> — epoch seconds of last modification, or empty.
file_mtime() {
  stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null
}

# Process / tty helpers (Linux)

# proc_dir — the /proc mount to read (testable).
proc_dir() { printf '%s' "${PSM_PROC_DIR:-/proc}"; }

# tty_nr_to_pts <tty_nr> — decode Linux tty_nr (stat field 7) to "pts/N" or "".
#   major = (tty_nr >> 8) & 0xff;  minor = tty_nr & 0xff
tty_nr_to_pts() {
  local nr major minor
  nr="$1"
  [ -n "$nr" ] && [ "$nr" -gt 0 ] 2>/dev/null || { printf '%s' ''; return; }
  major=$(( (nr >> 8) & 0xff ))
  minor=$(( nr & 0xff ))
  if [ "$major" -eq 136 ]; then
    printf 'pts/%s' "$minor"
  elif [ "$major" -eq 4 ]; then
    printf 'tty%s' "$minor"
  else
    printf 'tty%d/%d' "$major" "$minor"
  fi
}

# pid_start_epoch <pid> — process start time as epoch seconds (via btime).
pid_start_epoch() {
  local pid="$1" btime start hz proc
  proc="$(proc_dir)"
  btime="$(awk '/^btime / { print $2 }' "$proc/stat" 2>/dev/null)"
  start="$(awk '{ print $22 }' "$proc/$pid/stat" 2>/dev/null)"
  [ -n "$btime" ] && [ -n "$start" ] || { printf '%s' ''; return; }
  hz="$(getconf CLK_TCK 2>/dev/null || printf '100')"
  printf '%s' "$((btime + start / hz))"
}

# pid_exe_name <pid> — basename of /proc/<pid>/exe ("" when gone).
pid_exe_name() {
  local exe
  exe="$(readlink "$(proc_dir)/$1/exe" 2>/dev/null)" || { printf '%s' ''; return; }
  printf '%s' "${exe##*/}"
}

# pid_comm <pid> — /proc/<pid>/comm ("" when gone).
pid_comm() {
  cat "$(proc_dir)/$1/comm" 2>/dev/null
}

# pid_cmdline_first <pid> — first NUL-separated token of cmdline ("" when gone).
pid_cmdline_first() {
  tr '\0' '\n' < "$(proc_dir)/$1/cmdline" 2>/dev/null | head -n1
}

# pid_cwd <pid> — readlink of /proc/<pid>/cwd ("" when gone).
pid_cwd() {
  readlink "$(proc_dir)/$1/cwd" 2>/dev/null
}

# pid_tty_pts <pid> — "pts/N" for the process controlling tty ("" when none).
pid_tty_pts() {
  local nr
  nr="$(awk '{ print $7 }' "$(proc_dir)/$1/stat" 2>/dev/null)"
  tty_nr_to_pts "$nr"
}

# pid_is_pi <pid> — true when the process fingerprints as a pi agent:
# comm/cmdline match a known process name AND exe is a node-family runner.
pid_is_pi() {
  local pid="$1" comm first exe names
  comm="$(pid_comm "$pid")" || return 1
  first="$(pid_cmdline_first "$pid")"
  exe="$(pid_exe_name "$pid")"
  case "$exe" in node | nodejs | bun) ;; *) return 1 ;; esac
  names="${PSM_PROCESS_NAMES:-$(get_tmux_option @pi_tmux_process_names 'pi')}"
  for n in $names; do
    [ "$comm" = "$n" ] && return 0
    [ "$first" = "$n" ] && return 0
  done
  return 1
}

# pid_alive <pid> — process exists and belongs to us?
pid_alive() {
  [ -d "$(proc_dir)/$1" ] 2>/dev/null
}

# Path display

# display_path <path> — shorten $HOME to ~ for the picker.
display_path() {
  local home
  home="${HOME:-}"
  if [ -n "$home" ] && [ "${#1}" -ge "${#home}" ] && [ "${1:0:${#home}}" = "$home" ]; then
    printf '~%s' "${1:${#home}}"
  else
    printf '%s' "$1"
  fi
}

# project_name <cwd> <session-name-or-empty> — human project label.
project_name() {
  local cwd="$1" name="$2"
  if [ -n "$name" ]; then
    printf '%s' "$name"
  else
    printf '%s' "${cwd##*/}"
    [ -n "$cwd" ] && [ "$cwd" != "/" ] || printf '%s' "$cwd"
  fi
}

# JSON config (shared with the extension)

# psm_config_get <key> <default> — read a value from config.json (jq).
psm_config_get() {
  local file
  file="$(psm_config_file)"
  [ -f "$file" ] || { printf '%s' "$2"; return; }
  jq -r --arg k "$1" --arg d "$2" 'if has($k) then .[$k] | tostring else $d end' "$file" 2>/dev/null \
    || printf '%s' "$2"
}

# Logging (stderr, quiet unless PSM_DEBUG)

psm_debug() {
  [ -n "${PSM_DEBUG:-}" ] || return 0
  printf 'psm: %s\n' "$*" >&2
}

# Atomic file write helper for scripts

# psm_write_json <file> <json> — atomic (temp + rename) write, 0600 perms.
psm_write_json() {
  local file="$1" json="$2" dir tmp
  dir="$(dirname "$file")"
  mkdir -p "$dir" || return 1
  tmp="$dir/.tmp.$$.$RANDOM"
  printf '%s\n' "$json" > "$tmp" 2>/dev/null || return 1
  chmod 600 "$tmp" 2>/dev/null
  mv -f "$tmp" "$file" 2>/dev/null
}
