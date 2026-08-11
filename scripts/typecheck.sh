#!/usr/bin/env bash
# Type-check pi/extension.ts against the *installed* pi SDK.
#
# Locates the pi package (same resolution as the manager: `pi` on PATH,
# symlinks resolved) and compiles the extension with strict mode. Exits 0 on
# success. This is a developer tool — the extension itself is loaded by pi's
# runtime via jiti, which does not require types to pass.
set -uo pipefail

DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"   # project root

# Resolve pi's package root.
pi_pkg_dir() {
  local bin real pkg
  bin="$(command -v pi 2>/dev/null)" || return 1
  real="$(readlink -f "$bin" 2>/dev/null)" || real="$bin"
  pkg="$(dirname "$(dirname "$real")")"
  [ -f "$pkg/package.json" ] || return 1
  printf '%s' "$pkg"
}

PKG="$(pi_pkg_dir)" || { echo "pi not found on PATH — cannot type-check" >&2; exit 1; }
EXT="$DIR/pi/extension.ts"
[ -f "$EXT" ] || { echo "extension not found: $EXT" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/tsconfig.json" <<EOF
{
  "compilerOptions": {
    "target": "ES2022",
    "module": "commonjs",
    "moduleResolution": "node",
    "ignoreDeprecations": "6.0",
    "strict": true,
    "noEmit": true,
    "skipLibCheck": true,
    "types": ["node"],
    "typeRoots": ["$PKG/node_modules/@types"],
    "baseUrl": "$DIR",
    "paths": {
      "@earendil-works/pi-coding-agent": ["$PKG/dist/index.d.ts"]
    }
  },
  "files": ["$EXT"]
}
EOF

tsc -p "$TMP/tsconfig.json"
