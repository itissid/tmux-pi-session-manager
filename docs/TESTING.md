# Testing

Two layers of testing: an automated suite (mocked environment, no tmux/pi
needed) and a manual end-to-end plan against a real, **isolated** tmux server.

> ⚠️ Never run `tmux kill-server` on your real tmux server while testing —
> every command below uses the isolated socket `tmux -L pi-test`.

## Automated suite

```bash
./tests/run.sh
```

Runs every `tests/*.test.sh` in its own sandbox:

| Suite | Covers |
| --- | --- |
| `helpers` | hashing/naming (collision suffixes), tty_nr decode, time formatting, path display, config lookup, atomic writes, `/proc` helpers (`pid_is_pi` incl. `PSM_PROCESS_NAMES`, tty, cwd, start time, aliveness) |
| `agents` | discovery TSV: multi-agent-per-dir (`#1`/`#2`), extension-state enrichment, dedicated vs loose, status priority ordering, stale-state cleanup, tty-less skip, session-file fallback |
| `kill` | verified termination (TERM only, escalation to KILL), state cleanup on success / retention on failure, TOCTOU race refusal (process vanishes between discovery and kill), unknown targets |
| `notify` | waiting/error notification + dedup, WAITING→WORKING→WAITING re-notify, `min_attention_duration_ms` gating, config gates, stale cleanup, `notify_id` stability/range |
| `cli` | `list --json` shape, `current`, `status` (state json + fallback row), `launch` (session naming, `@pi_tmux_managed`/origin markers, env-prefix injection, nesting refusal), `resume`, extension install/uninstall, `doctor`, unknown command |

Sandbox mechanics (`tests/lib.sh`):

- fake `/proc` via `PSM_PROC_DIR` (`make_proc_pid` builds `comm`, `cmdline`,
  `exe` symlink, `stat` with `tty_nr` + `starttime`, `cwd`, and `/proc/stat`
  with `btime`)
- mocked `tmux` answering `list-panes`/`list-sessions`/`show-option`/
  `show-options`/`display-message` from scenario files, logging every call
- mocked `notify-send` and `kill` (the latter can "really" kill a fake pid to
  test TERM-only paths, or simulate a mid-discovery death via the
  `PSM_TMUX_RACE_SESSION`/`PSM_TMUX_RACE_PID` hook)

## Manual end-to-end plan (isolated server)

### 0. Setup

```bash
PSM=/path/to/tmux-pi-session-manager
cat > /tmp/psm-tmux <<'EOF'
#!/bin/sh
exec tmux -L pi-test "$@"
EOF
chmod +x /tmp/psm-tmux
export PSM_TMUX=/tmp/psm-tmux
export PSM_STATE_DIR=/tmp/psm-e2e/state
export PI_CODING_AGENT_DIR=/tmp/psm-e2e/agent
mkdir -p /tmp/psm-e2e/state /tmp/psm-e2e/agent
tmux -L pi-test new-session -d -s work -c /tmp
```

### 1. Discovery of manually-launched agents

```bash
tmux -L pi-test new-window -t work "pi"
# wait a few seconds
"$PSM/bin/pi-tmux" list
```

Expect: one row, kind `loose`, status `?` (no extension yet), loc
`work:1.2`.

### 2. Launch → extension → status

```bash
"$PSM/bin/pi-tmux" launch --dir /tmp --no-attach
sleep 4
"$PSM/bin/pi-tmux" list
```

Expect: a new `pi-<hash>` session marked `@pi_tmux_managed=1`; the launched
pi (it inherits `PI_CODING_AGENT_DIR`) loads the extension and writes
`/tmp/psm-e2e/state/agents/<uuid>.json`; the row now shows `IDLE` and the
uuid as session id.

### 3. Multiple agents per directory

```bash
"$PSM/bin/pi-tmux" launch --dir /tmp --no-attach
"$PSM/bin/pi-tmux" list
```

Expect: a second session `pi-<hash>-2`; both rows keep their own identity and
get `#1` / `#2` suffixes.

### 4. Status transitions

Attach to the launched session (`tmux attach -t pi-<hash>` in another
terminal, or via the popup from a real client), type a prompt, and watch:

- while the agent works: status `WORKING`, `last_activity_at` updates
- an error mid-turn: status `ERROR` + error notification (see `notify.log`
  via `PSM_NOTIFY_SEND` wrapper)
- on return to the prompt: `WAITING`, then `IDLE` after
  `min_attention_duration_ms`

### 5. Jump & focus

```bash
"$PSM/bin/pi-tmux" focus <pid>          # from a real client
"$PSM/bin/pi-tmux" pick                 # opens the fzf popup; enter jumps
```

### 6. Kill

```bash
"$PSM/bin/pi-tmux" kill <pid> --yes
"$PSM/bin/pi-tmux" list                 # row gone, session closed, state removed
```

### 7. Notifications (bash reconcile)

```bash
"$PSM/bin/pi-tmux" notify
"$PSM/bin/pi-tmux" notify               # second run: nothing new (dedup)
```

### 8. Cleanup

```bash
tmux -L pi-test kill-server
rm -rf /tmp/psm-e2e /tmp/psm-tmux
```

## Environment regression checklist

- [ ] paths containing spaces and Unicode (launch/list/kill round-trip)
- [ ] `PSM_TMUX` pointing at a different server
- [ ] missing `jq`/`fzf`/`notify-send` degrade gracefully (`pi-tmux doctor`)
- [ ] stale state files removed without crashing discovery
- [ ] no notification payload contains prompt/credential content
