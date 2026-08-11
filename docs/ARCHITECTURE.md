# Architecture — tmux-pi-session-manager

This document records the design decisions of `tmux-pi-session-manager`, why each
decision was made, and how the pieces fit together. It was written after studying:

- [craftzdog/tmux-claude-session-manager](https://github.com/craftzdog/tmux-claude-session-manager) (the inspiration)
- the official Pi documentation and source (this machine: pi 0.84.1,
  `@earendil-works/pi-coding-agent`)
- tmux (3.7) and fzf (0.74) documentation
- Linux `/proc`, tty, and desktop-notification (D-Bus) semantics
- a real-world Pi state extension (`herdr-agent-state.ts`) as a cross-check

## 0. Claude vs Pi — the internal technical analysis

### How the original discovers Claude agents

`claude agents --json` is the source of truth. Claude Code runs a supervisor
daemon; each session self-reports `busy|waiting|idle` to it, and that command
publishes an aggregated list with `pid`, `status`, `sessionId`, `cwd`,
`startedAt`. The plugin:

1. calls `claude agents --json`
2. joins `pid → tty` (`ps -Ao pid=,tty=`)
3. joins `tty → tmux pane` (`tmux list-panes -a -F '#{pane_tty} ...'`)
4. derives age from the transcript file mtime (Claude reports only `startedAt`)

Identity is the **Claude process**, not the tmux session — that is what lets
several agents in one directory each get their own row. The launcher creates a
dedicated `claude-<hash-of-dir>` tmux session and resumes it in a popup; loose
agents (started by hand in a normal pane) are focused in place. The picker is
fzf inside `tmux display-popup`, with `capture-pane` preview and a `ctrl-x` kill.

### What Pi offers instead

| Need | Claude (original) | Pi (this project) |
|------|-------------------|-------------------|
| Aggregated agent list | `claude agents --json` (supervisor daemon) | **none** — Pi has no supervisor |
| Per-session status | daemon-published `busy/waiting/idle` | **extension events** (`agent_start`, `agent_settled`, `message_end`, `input`, …) |
| Session identity | Claude session id | Pi session UUID: `ctx.sessionManager.getSessionId()` (persisted in the session-file header `{"type":"session","id":"<uuid>",...}`) |
| Session file | `~/.claude/projects/*/<id>.jsonl` | `<agent-dir>/sessions/--<cwd>--/<ts>_<uuid>.jsonl` |
| Last activity | transcript mtime only | extension `last_activity_at` (event-driven); fallback: session-file mtime / process start |
| Process fingerprint | `claude` command name | `/proc/<pid>/cmdline == "pi"`, `comm == "pi"`, `exe → node` (verified empirically: pi's `process.title` rewrites argv[0] to `"pi"`) |
| Resume | — | `pi --session <path|id>`, `pi -c` |

### What must come from tmux/process inspection (not Pi)

- **pid → tty** — `/proc/<pid>/stat` field 7 (`tty_nr`), decoded `major<<8|minor`
  → `/dev/pts/N` (Linux).
- **tty → tmux pane** — `tmux list-panes -a -F '#{pane_tty} …'`.
- **pane → window → session** — tmux format variables in the same call.
- **process liveness** — `/proc/<pid>` existence + fingerprint check (never
  trust a PID; PID reuse is real).
- **pane content preview** — `tmux capture-pane`.

### What should come from a Pi extension

Everything the process/tmux layers cannot see:

- session id, session file, display name (`session_start`, `session_info_changed`)
- `working` (between `agent_start` and `agent_settled`)
- `waiting` (agent settled; pi is at the prompt awaiting user input)
- `error` (assistant `message_end` with `stopReason: "error"` / `auto_retry_end` failure)
- `idle` (session open, no work done yet)
- `last_activity_at` (every turn/tool/stream event)
- user-input timestamps (`input` event) — used to decide "needs attention"

The extension writes one JSON file per session; no daemon, no socket.

## 1. Components and data flow

```
┌──────────────────────────  pi (interactive TUI in a tmux pane)  ──────────────┐
│  pi/extension.ts  (auto-loaded from <agent-dir>/extensions/)                  │
│    • subscribes to Pi lifecycle events                                        │
│    • derives status + activity                                                │
│    • writes  $XDG_STATE_HOME/pi-tmux-session-manager/agents/<session-id>.json │
│    • sends desktop notifications on transitions (deduplicated)                │
└───────────────────────────────────────────────────────────────────────────────┘
                                   │ file-based state (no daemon)
                                   ▼
┌────────────────────────────────  manager (bash)  ─────────────────────────────┐
│ scripts/agents.sh   discovery: /proc scan + state files + tmux pane mapping   │
│ scripts/picker.sh   fzf picker (tmux display-popup) with live capture-pane    │
│ scripts/launch.sh   launch/resume pi in a dedicated tmux session              │
│ scripts/kill.sh     verified, graceful termination + state cleanup            │
│ scripts/notify.sh   reconcile/watch notifications (optional watcher)          │
│ scripts/helpers.sh  paths, options, validation, formatting                    │
│ tmux/tmux-pi-session-manager.tmux   key bindings (prefix+p / prefix+Shift+p)  │
│ bin/pi-tmux         CLI: launch list pick current kill focus notify resume …  │
└───────────────────────────────────────────────────────────────────────────────┘
                                   │
                                   ▼
                      tmux (sessions/windows/panes), fzf, notify-send (D-Bus)
```

There is **no daemon by default**. State flows from the extension to disk; the
manager reads disk on demand (picker, list, current). The only background-ish
piece is an *optional* `pi-tmux notify --watch` loop for "agent died" events,
off by default.

## 2. Identity model

An agent is identified by the **Pi session UUID** (primary), cross-checked
against **PID** and **tmux pane id**:

```
Pi session UUID ──┐
PID (with fingerprint) ──┼─→ one picker row per agent
tmux pane id ─────┘
```

- Two agents in the same directory get different UUIDs → separate rows.
- The manager never uses the directory alone as identity.
- When the extension is not installed, identity degrades to
  `pid:<pid>`; the row is still listed (status `unknown`), and the session file
  is located by matching its creation timestamp to the process start time.

### State file (`agents/<uuid>.json`)

Written by the extension (atomic rename). Example:

```json
{
  "schema": 1,
  "session_id": "019ff169-...",
  "session_file": "/home/dox/.config/pi/agent/sessions/--home-dox-Developer--/2026-08-11T15-20-38-079Z_019ff169-....jsonl",
  "session_name": null,
  "pid": 53221,
  "cwd": "/tmp",
  "status": "waiting",
  "started_at": 1786461600000,
  "updated_at": 1786461612345,
  "last_activity_at": 1786461612000,
  "last_user_input_at": 1786461609000,
  "last_error_at": null,
  "has_worked": true,
  "last_stop_reason": "stop",
  "is_blocked": false,
  "blocked_at": null,
  "blocked_reason": null,
  "notify": {
    "last_sent_status": "waiting",
    "last_sent_at": 1786461612000
  }
}
```

Only metadata required by the manager. No prompts, no message content.

## 3. Status derivation (honest mapping to Pi semantics)

Pi has **no** `busy/waiting/idle` supervisor. We derive status from the event
stream with this state machine (kept inside the extension):

```
session_start      → reset; publish (idle)
input              → last_user_input_at = now; agent_active = true; force_unblock; publish (working)
agent_start        → agent_active = true; has_worked = true; last_error_at = null; force_unblock; publish (working)
message_end        → if assistant && (stopReason=="error" || errorMessage): last_error_at = now
auto_retry_end     → if !success: last_error_at = now; agent_active = false
agent_settled      → agent_active = false; publish (derived)
tool_execution_start / tool_execution_end → last_activity_at = now; if toolName == "ask_user_question": block / release
turn_start / tool_execution_* / message_update / message_end → last_activity_at = now
permission:ask / permission:resolved (extension events) → block / release
session_shutdown   → write final state, flush
```


Derived status at publish time (priority order):

1. `blocked` — `is_blocked` (an `ask_user_question` dialog or a permission
   confirmation is open; the agent waits on *you*, not the model)
2. `working` — `agent_active`
3. `error` — `last_error_at > last_user_input_at` (an error happened and the
   user has not responded since)
4. `waiting` — `has_worked` (a run completed; pi is at the prompt awaiting input)
5. `idle` — session open, no work yet (fresh session)

Why this is defensible:

- **blocked** comes from real signals: `tool_execution_start/end` with
  `toolName == "ask_user_question"` (the tool blocks until the user answers)
  and `permission:ask` / `permission:resolved` published by permission-gate
  extensions. A counter tracks concurrent blockers so overlapping dialogs
  cannot leave the state stuck; safety clears fire on `input` and
  `agent_start`. `blocked_reason` is `question` or `permission`.
- **working** is exactly `!ctx.isIdle()` from the agent events.
- **waiting** = "pi is at the editor waiting for your input after doing work".
  This is the resting state of interactive pi after any turn, and the dedup
  rules (section 6) keep notifications sane. It is *not* invented: the TUI
  genuinely waits on user input here.
- **error** uses Pi's own terminal failure signals. Tool-level `isError`
  results (e.g. a failed `bash`) are *not* fatal — the agent continues — so
  they are deliberately excluded.
- **idle** = fresh/empty session.

The picker shows a fourth derived value `unknown` when no extension state
exists (grey). Statuses sort: `blocked` < `error` < `waiting` < `working` <
`idle` (what needs you floats up).

## 4. Discovery (agents.sh)

1. **Scan processes** — `ps -C pi` (matches `comm == "pi"`), then verify each
   candidate: `/proc/<pid>/cmdline` first token is `pi` *and*
   `/proc/<pid>/exe` basename is a known runner (`node`, `nodejs`, `bun`).
   Reading `/proc` directly is not required — `ps` + `/proc` verification is
   cheap and portable. (Config: `@pi_tmux_process_names`, default `pi`, for
   rebranded distributions whose `APP_NAME` differs.)
   - pid → tty: `/proc/<pid>/stat` field 7 → `pts/N`
   - pid → cwd: `readlink /proc/<pid>/cwd`
   - pid → start: `/proc/<pid>/stat` field 22 → btime-adjusted epoch
2. **Build tty → pane map** — one `tmux list-panes -a -F` call carrying
   `pane_tty`, `pane_id`, `session_name`, `window_index`, `pane_index`,
   `window_name`, `session_id`. Strip the `/dev/` prefix on `pane_tty`.
3. **Join** — each pi process whose tty is in the map is inside tmux. The pane
   gives session/window/location. Verified empirically: `pane_pid` is the
   *shell* pid when pi runs under bash, so **tty is the reliable join**, never
   `pane_pid`. `pane_current_command == "pi"` is a secondary signal only.
4. **Enrich with extension state** — for each state file whose pid is alive and
   matches a discovered process, merge `session_id`, `status`,
   `last_activity_at`, `session_name`, `started_at`. State files with a dead
   pid, or whose pid no longer fingerprints as pi, are removed (stale cleanup).
5. **Fallback identity** (no extension): locate the session file under
   `<agent-dir>/sessions/--<encoded-cwd>--/` whose creation timestamp best
   matches the process start; status `unknown`.
6. **Render TSV** — one row per agent:

```
rank \t pane_id \t pid \t kind \t session_id \t status \t project \t dir \t age \t loc
```

`rank/pane/pid/kind/session_id` are hidden from display via fzf `--with-nth`.
`kind` is `dedicated` (launched by the manager; tmux session carries the
`@pi_tmux_managed` marker) or `loose` (any other pane). `project` is the
session display name, else the cwd basename, with a ` #N` suffix per directory
when several agents share a cwd (N by `started_at`). `age` is
`now - last_activity_at` (12s/2m/14m/1h) from the state file; falls back to
session-file mtime, then process start. Extension timestamps are
epoch-**milliseconds** (`Date.now()`); discovery normalizes them to seconds
before computing ages/ordering.

## 5. Launch, jump, kill

### launch

`pi-tmux launch [--dir D] [--name N] [--resume ID] [-- args...]`

- Creates a new dedicated tmux session `pi-<hash8-of-dir>[-<n>]` (hash of the
  resolved directory; `-<n>` when the name is taken — multiple agents per
  directory), window `pi`, cwd D, running `pi [args]` (or
  `pi --session <file>` for resume).
- Marks it managed: `tmux set-option -t <sess> @pi_tmux_managed 1` and records
  the origin window (`@pi_tmux_origin`) for jump-back.
- Explicit env overrides (`PSM_STATE_DIR`, `PSM_CONFIG_DIR`, `PI_CODING_AGENT_DIR`, …)
  are injected **into the command itself** (`env VAR=… pi …`), because tmux
  spawns the first command with the *server's* process environ — session/global
  env overrides of existing variables proved unreliable across tmux builds.
- Attaches in a popup when invoked from inside tmux
  (`tmux display-popup -E "tmux attach-session -t <sess>"`), or with a plain
  `attach-session` when invoked outside tmux.
- Refuses to nest a dedicated session inside another dedicated session (shows a
  hint pointing at the picker). The check reuses the shared
  `tmux_session_managed` helper (helpers.sh) — `display-message -p '#S'` +
  the `@pi_tmux_managed` marker.
- Auto-installs the bundled extension (`pi/extension.ts` →
  `<agent-dir>/extensions/`) when missing — opt out with
  `@pi_tmux_auto_install_extension off`.

### jump (picker Enter)

- `dedicated` → the popup re-attaches to the agent's tmux session
  (`tmux attach-session` inside the popup), while the host client first switches
  to the origin window (best-effort, when known).
- `loose` → `tmux switch-client -c <host> -t <session>`, then
  `select-window` / `select-pane` on the exact pane; the popup closes.
- If the picker was opened from *inside* a dedicated-session popup, that popup
  is detached first and the picker reopens full-size on the outer host client
  (ported from the original; avoids popup-in-popup).

### kill

`pi-tmux kill <pid|session-id|pane-id>`

1. Resolve to a pid; **verify** `/proc/<pid>/exe` → node and comm/cmdline = pi.
   Refuse anything else.
2. `SIGTERM`, wait up to 3s, `SIGKILL` if still alive (never kill unrelated
   processes).
3. Remove the state file. If the agent was in a dedicated session, the session
   dies with its last window (pi is the window command); a loose pane keeps its
   shell.
4. From the picker, `ctrl-x` asks for confirmation via a small nested fzf
   (`@pi_tmux_kill_confirm`, default on), then reloads the list.

## 6. Notifications (event-driven, deduplicated)

Sent by the **extension** (in-process, immediate — no polling), using
`notify-send` (`notification_backend = auto` → notify-send when present, else
no-op; `off` disables). Config lives in
`$XDG_CONFIG_HOME/pi-tmux-session-manager/config.json`, read by both the
extension and the manager:

```json
{
  "notify_on_waiting": true,
  "notify_on_error": true,
  "notify_on_done": false,
  "notification_backend": "auto",
  "min_attention_duration_ms": 5000
}
```

- **Events**: transition into `blocked` (question or permission dialog —
  content-free body), transition into `waiting` (agent finished a turn; pi
  awaits input), transition into `error`, and (optional, off by default) clean
  completion (`notify_on_done`).
- **Dedup**: the `notify.last_sent_status` field is compared *before* sending;
  a notification is sent only when the status changes. `WAITING → WAITING`
  (no change) sends nothing; `WAITING → WORKING → WAITING` is a change and
  sends again. Exactly the spec's dedup contract.
- **Identity**: notifications use `notify-send -r <id>` where `<id>` is a
  stable hash of the session UUID, so each agent owns its notification slot
  (updates replace, no duplicates, independent per agent).
- **Content safety**: body is `project · agent #N` + `cwd` + a generic message.
  **Never** prompts, tool args, file contents, tokens, or API keys.
- **Focus**: the manager ships `pi-tmux focus <pid|id>` (jump the invoking
  client to the agent's pane). Notification *actions* are not required for core
  function; a mako/daemon snippet showing how to bind a click to
  `pi-tmux focus` is documented.
- `pi-tmux notify --reconcile` replays missed transitions from the state files
  (used by tests and the optional watcher). The optional
  `pi-tmux notify --watch` loop (default off) also notices agents that died
  while working and cleans stale state.

Why the extension (not the manager) sends notifications: Pi's event stream is
the *only* real-time signal; the manager only runs when the user opens the
picker. Polling would mean a daemon, which the spec forbids by default.

## 7. Config & path resolution

Everything respects the environment:

- State dir: `$PSM_STATE_DIR` → `$XDG_STATE_HOME/pi-tmux-session-manager` →
  `~/.local/state/pi-tmux-session-manager`
- Config dir: `$PSM_CONFIG_DIR` → `$XDG_CONFIG_HOME/pi-tmux-session-manager` →
  `~/.config/pi-tmux-session-manager`
- Pi agent dir (sessions/extensions): `$PI_CODING_AGENT_DIR` →
  `~/.config/pi/agent` … wait — Pi itself resolves it as
  `$PI_CODING_AGENT_DIR` → `$HOME/<piConfig.configDir>/agent` where
  `piConfig.configDir` is read from the **installed pi package.json**
  (`@earendil-works/pi-coding-agent` ships `.pi`; rebrands differ). The manager
  resolves the same way: env var first, then the package's `piConfig.configDir`
  (found via `readlink -f $(command -v pi)`), then a legacy `~/.pi/agent`
  fallback. This machine uses `PI_CODING_AGENT_DIR=$HOME/.config/pi/agent/`
  set in `~/.config/zsh/.zshenv`.
- tmux options (`@pi_tmux_*`) follow the original plugin's style, with
  defaults for keys `p` (picker) / `P` (launch), popup 90%/90%, prefix `pi-`.

## 8. Security notes

- No `eval`; fzf extra options are split with `set --` / arrays, never `eval`'d.
- All tmux targets use pane/session ids from tmux's own output; shell-quoted
  through `#{q:...}` where passed from bindings.
- PIDs are validated against `/proc` fingerprints before signals; paths with
  spaces/Unicode are handled by keeping data in TSV (tab-delimited) and using
  `printf %s` (no word splitting), plus fzf `--delimiter` for the metadata.
- Notification bodies contain no user content.
- State files are `0600`; the state dir is `0700`.

## 9. Testing strategy

`tests/` run in a sandbox: `PATH` points at stub `tmux`/`ps`/`pi`/`notify-send`
binaries, `PSM_*` env vars redirect all paths, and a fake `/proc` tree is
provided via `PSM_PROC_DIR`. This exercises discovery, mapping, state cleanup,
dedup, and TSV rendering without a real pi or tmux. A separate manual test
plan (docs/TESTING.md) covers real tmux/pi integration, including multiple
agents per directory and notification timing.

## 10. Deviations from the original / from the spec

- **Status source**: Pi has no `agents --json`; we use an extension + file
  state instead of a supervisor daemon.
- **Notifications**: sent by the extension (event-driven) rather than a
  manager-side poller, to honor the no-daemon requirement; `notify --watch`
  remains an opt-in for death detection.
- **Resume**: uses Pi's official `--session` flag; the manager records session
  files in state so `pi-tmux resume <id>` can relaunch the exact session.
- **Process identity**: fingerprint is `comm/cmdline == APP_NAME (pi)` +
  node-family `exe`, verified empirically (process.title rewrites argv[0]).
- **Launcher**: always creates a distinct session per launch (no silent
  re-attach), because multiple agents per directory is a hard requirement;
  re-attaching to an existing one is one `pi-tmux launch` away via the picker.
