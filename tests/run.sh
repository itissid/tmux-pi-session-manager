#!/usr/bin/env bash
# Test runner — runs every tests/*.test.sh in its own sandbox and reports.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="${TEST_ROOT:-/tmp/psm-tests}"
rm -rf "$TEST_ROOT"
mkdir -p "$TEST_ROOT"

pass_total=0
fail_total=0
declare -a failures

for suite in "$ROOT"/tests/*.test.sh; do
  [ -e "$suite" ] || continue
  name="$(basename "$suite" .test.sh)"
  printf '\n\033[1m[%s]\033[0m\n' "$name"
  bash "$suite" 2>&1 | sed 's/^/  /'
  res_file="$TEST_ROOT/results/$name"
  if [ -f "$res_file" ]; then
    read -r p f < "$res_file"
    pass_total=$((pass_total + p))
    fail_total=$((fail_total + f))
  else
    printf '  \033[31mno results file — suite crashed?\033[0m\n'
    fail_total=$((fail_total + 1))
  fi
done

printf '\n\033[1m==== %s passed, %s failed ====\033[0m\n' "$pass_total" "$fail_total"
if [ "$fail_total" -gt 0 ]; then
  exit 1
fi
exit 0
