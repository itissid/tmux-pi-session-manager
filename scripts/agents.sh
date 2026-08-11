#!/usr/bin/env bash
# Emit one TSV row per running Pi agent that lives in a tmux pane.
#
# Discovery pipeline (see docs/ARCHITECTURE.md):
#   1. scan /proc for pi processes (comm/cmdline == "pi", exe -> node family)
#   2. pid -> tty (/proc/<pid>/stat tty_nr), pid -> cwd, pid -> start time
#   3. tty -> tmux pane (tmux list-panes -a), pane -> window -> session
#   4. enrich from extension state files (agents/<session-id>.json), clean stale
#   5. fallback identity for pi without the extension (session-file matching)
#
# Row (TSV, 11 visible/relevant fields + 2 internal):
#   1  rank       hidden — sort order (error < waiting < working < idle < unknown)
#   2  pane_id    hidden — tmux pane id (jump, preview)
#   3  pid        hidden — pi process pid (kill)
#   4  kind       hidden — dedicated|loose
#   5  session_id hidden — pi session uuid (or pid:<pid> without extension)
#   6  age_secs   hidden — numeric age for sorting
#   7  status     visible — "● WORKING" &c (ANSI)
#   8  project    visible — session name or dir basename (+ " #N" per dir)
#   9  dir        visible — cwd, ~-shortened
#   10 age        visible — "12s" / "2m" / "14m" / "1h"
#   11 loc        visible — "session:window.pane"
#   12 raw_cwd    internal — grouping for " #N" suffixing
#   13 started_at internal — ordering within a directory
set -uo pipefail
DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=helpers.sh
. "$DIR/helpers.sh"

PSM_TMUX="${PSM_TMUX:-tmux}"

# 1+2. pi processes: pid / tty / cwd / start
pi_processes() {
  local proc d pid tty cwd start
  proc="$(proc_dir)"
  for d in "$proc"/[0-9]*; do
    [ -d "$d" ] || continue
    pid="${d##*/}"
    pid_is_pi "$pid" || continue
    tty="$(pid_tty_pts "$pid")"
    cwd="$(pid_cwd "$pid")"
    start="$(pid_start_epoch "$pid")"
    printf '%s\t%s\t%s\t%s\n' "$pid" "$tty" "$cwd" "$start"
  done
}

# 3. tmux pane map: tty -> pane/window/session (one tmux call)
# Emits: tty_without_dev \t pane_id \t session_name \t loc
tmux_pane_map() {
  "$PSM_TMUX" list-panes -a -F $'#{pane_tty}\t#{pane_id}\t#{session_name}\t#{session_name}:#{window_index}.#{pane_index}' 2>/dev/null |
    sed 's#^/dev/##'
}

# 4. Extension state files (agents/<session-id>.json)
# Loads state for live pi processes into STATE_BY_PID (pid -> payload) and
# removes stale files. Sets STALE_CLEANED=1 when anything was removed.
STATE_BY_PID=()
STALE_CLEANED=0
load_state_files() {
  local adir f sid pid status cwd sname started activity sfile
  adir="$(psm_agents_dir)"
  [ -d "$adir" ] || return 0
  while IFS= read -r f; do
    [ -f "$f" ] || continue
    sid="$(basename "$f" .json)"
    pid="$(jq -r '.pid // empty' "$f" 2>/dev/null)" || continue
    if [ -z "$pid" ] || ! pid_alive "$pid" || ! pid_is_pi "$pid"; then
      psm_debug "removing stale state $f (pid=$pid)"
      rm -f "$f"
      STALE_CLEANED=1
      continue
    fi
    status="$(jq -r '.status // "unknown"' "$f" 2>/dev/null)"
    cwd="$(jq -r '.cwd // ""' "$f" 2>/dev/null)"
    sname="$(jq -r '.session_name // ""' "$f" 2>/dev/null)"
    started="$(jq -r '.started_at // ""' "$f" 2>/dev/null)"
    activity="$(jq -r '.last_activity_at // .updated_at // ""' "$f" 2>/dev/null)"
    sfile="$(jq -r '.session_file // ""' "$f" 2>/dev/null)"
    STATE_BY_PID["$pid"]="$sid|$status|$cwd|$sname|$started|$activity|$sfile"
  done < <(find "$adir" -maxdepth 1 -name '*.json' -type f 2>/dev/null)
}

# 5. Fallback identity: match a session file to a pi process (no extension)
# find_session_for <cwd> <start> — echoes the session file whose header cwd
# matches and whose creation time is closest to the process start, or nothing.
find_session_for() {
  local cwd="$1" start="$2" sess_dir enc best best_delta f header hcwd hts delta
  sess_dir="$(pi_sessions_dir)"
  [ -d "$sess_dir" ] || return 0
  enc="${cwd#/}"
  enc="${enc//\//-}"
  enc="--${enc}--"
  sess_dir="$sess_dir/$enc"
  [ -d "$sess_dir" ] || return 0
  best=""
  best_delta=999999999
  for f in "$sess_dir"/*.jsonl; do
    [ -f "$f" ] || continue
    header="$(head -n1 "$f" 2>/dev/null)" || continue
    hcwd="$(printf '%s' "$header" | jq -r '.cwd // ""' 2>/dev/null)"
    [ "$hcwd" = "$cwd" ] || continue
    hts="$(printf '%s' "$header" | jq -r '.timestamp // ""' 2>/dev/null)"
    hts="$(date -d "$hts" +%s 2>/dev/null)"
    [ -n "$hts" ] || continue
    delta=$((start - hts))
    [ "$delta" -lt 0 ] && delta=$((-delta))
    if [ "$delta" -lt "$best_delta" ]; then
      best_delta="$delta"
      best="$f"
    fi
  done
  printf '%s' "$best"
}

# Display helpers
status_display() {
  case "$1" in
    error)   printf '\033[31m● ERROR  \033[0m' ;;
    waiting) printf '\033[33m● WAITING\033[0m' ;;
    working) printf '\033[34m● WORKING\033[0m' ;;
    idle)    printf '\033[32m● IDLE   \033[0m' ;;
    *)       printf '\033[90m● ?      \033[0m' ;;
  esac
}

status_rank() {
  case "$1" in
    error) printf '0' ;;
    waiting) printf '1' ;;
    working) printf '2' ;;
    idle) printf '3' ;;
    *) printf '4' ;;
  esac
}

# Main
main() {
  local now
  now="$(now_epoch)"

  load_state_files

  # tty -> pane/session/loc map from tmux
  local -A pane_by_tty sess_by_tty loc_by_tty
  local tty pane sess loc
  while IFS=$'\t' read -r tty pane sess loc; do
    [ -n "$tty" ] || continue
    pane_by_tty["$tty"]="$pane"
    sess_by_tty["$tty"]="$sess"
    loc_by_tty["$tty"]="$loc"
  done < <(tmux_pane_map)

  # First pass: emit rows (13 fields, see header).
  local rows=()
  local pid tty2 cwd start sid status project age_secs loc kind
  local payload sid2 stat2 cwd2 sname2 started2 activity2 sfile2
  local sfile_fallback fallback_mtime use_sname started2_num

  while IFS=$'\t' read -r pid tty2 cwd start; do
    [ -n "$tty2" ] || continue                # pi has no controlling tty
    pane="${pane_by_tty[$tty2]:-}"
    [ -n "$pane" ] || continue                # not inside a tmux pane
    sess="${sess_by_tty[$tty2]}"
    loc="${loc_by_tty[$tty2]}"

    payload="${STATE_BY_PID[$pid]:-}"
    if [ -n "$payload" ]; then
      IFS='|' read -r sid2 stat2 cwd2 sname2 started2 activity2 sfile2 <<< "$payload"
      sid="$sid2"; status="$stat2"; use_sname="$sname2"
      [ -n "$cwd2" ] && cwd="$cwd2"
      started2_num="$(printf '%s' "$started2" | awk '{ printf "%d", $1 }')"
      [ "$started2_num" -gt 0 ] 2>/dev/null || started2_num="$start"
      # the extension stores epoch-milliseconds; discovery works in seconds
      if [ "$started2_num" -gt 100000000000 ] 2>/dev/null; then
        started2_num=$((started2_num / 1000))
      fi
      if [ -n "$activity2" ] && [ "$activity2" -gt 0 ] 2>/dev/null; then
        age_secs=$(( (now * 1000 - activity2) / 1000 ))
        [ "$age_secs" -lt 0 ] && age_secs=0
      else
        age_secs=""
      fi
    else
      sid="pid:$pid"; status="unknown"; use_sname=""
      sfile_fallback="$(find_session_for "$cwd" "$start")"
      fallback_mtime="$(file_mtime "$sfile_fallback")"
      if [ -n "$fallback_mtime" ]; then
        age_secs=$((now - fallback_mtime)); [ "$age_secs" -lt 0 ] && age_secs=0
      else
        age_secs=$((now - start)); [ "$age_secs" -lt 0 ] && age_secs=0
      fi
      started2_num="$start"
    fi

    [ -n "$cwd" ] || cwd=""
    if tmux_session_managed "$sess" 2>/dev/null; then kind="dedicated"; else kind="loose"; fi
    project="$(project_name "$cwd" "$use_sname")"

    rows+=("$(printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' \
      "$(status_rank "$status")" "$pane" "$pid" "$kind" "$sid" "$age_secs" \
      "$(status_display "$status")" "$project" "$(display_path "$cwd")" \
      "$(fmt_age "$age_secs")" "$loc" "$cwd" "$started2_num")")
  done < <(pi_processes)

  # Second pass (awk): per-directory " #N" suffixing + final 11-field rows,
  # then sort by rank, then age. Emits nothing when there are no agents.
  [ "${#rows[@]}" -gt 0 ] || return 0
  printf '%s\n' "${rows[@]}" | awk -F'\t' -v OFS='\t' '
    { rows[NR]=$0; cwd[NR]=$12; start[NR]=$13; cnt[$12]++ }
    END {
      for (i = 1; i <= NR; i++) {
        idx[i] = 1
        for (j = 1; j <= NR; j++)
          if (cwd[j] == cwd[i] && start[j] < start[i]) idx[i]++
      }
      for (i = 1; i <= NR; i++) {
        n = split(rows[i], F, "\t")
        if (cnt[cwd[i]] > 1) F[8] = F[8] " #" idx[i]
        out[i] = F[1] "\t" F[2] "\t" F[3] "\t" F[4] "\t" F[5] "\t" F[6] "\t" F[7] "\t" F[8] "\t" F[9] "\t" F[10] "\t" F[11]
      }
      for (i = 1; i <= NR; i++) print out[i]
    }' | sort -t$'\t' -k1,1n -k6,6n
}

main "$@"
