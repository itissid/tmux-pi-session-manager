#!/usr/bin/env bash
# Plugin binding behavior across tmux config reloads.
set -u
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SUITE_NAME="plugin"
make_sandbox
install_mocks
mkdir -p "$SB/bindings"
export PSM_TEST_BINDINGS="$SB/bindings"

# Minimal stateful tmux: unlike the common mock, list-keys reflects bind-key.
cat > "$SB/bin/tmux" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  show-option)
    [ "$3" = @pi_tmux_list_key ] && printf 'g\n'
    ;;
  list-keys)
    [ -f "$PSM_TEST_BINDINGS/$4" ] && cat "$PSM_TEST_BINDINGS/$4"
    ;;
  bind-key)
    printf 'bind-key -T prefix %s %s "%s"\n' "$4" "$5" "$6" > "$PSM_TEST_BINDINGS/$4"
    printf 'bind %s\n' "$4" >> "$PSM_TMUX_LOG"
    ;;
  display-message)
    printf '%s\n' "$2" >> "$PSM_TMUX_LOG"
    ;;
esac
EOF
chmod +x "$SB/bin/tmux"
plugin="$ROOT/tmux/tmux-pi-session-manager.tmux"

t_section "reloading preserves the plugin's own binding without warning"
"$plugin"
first_binding="$(cat "$SB/bindings/g")"
"$plugin"
assert_eq "prefix+g still uses the plugin" "$(cat "$SB/bindings/g")" "$first_binding"
assert_eq "no false collision warning" "$(grep -c 'already bound' "$PSM_TMUX_LOG" || true)" "0"
assert_eq "each key bound only once" "$(grep -c '^bind ' "$PSM_TMUX_LOG")" "2"

t_section "genuine user binding remains protected"
printf 'bind-key -T prefix g display-message "user command"\n' > "$SB/bindings/g"
"$plugin"
assert_contains "user binding preserved" "$(cat "$SB/bindings/g")" "user command"
assert_eq "real collision warns once" "$(grep -c 'prefix+g is already bound' "$PSM_TMUX_LOG")" "1"

mkdir -p "$TEST_ROOT/results"
printf '%s %s\n' "$PASS" "$FAIL" > "$TEST_ROOT/results/$SUITE_NAME"
