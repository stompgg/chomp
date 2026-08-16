#!/usr/bin/env bash
# chomp bot benchmark — setup and scoring.
#
#   ./bench.sh setup              generate the engine and build (first time, slow)
#   ./bench.sh run --bot greedy   score a bot against the ladder
#   ./bench.sh test               run the bot smoke tests
#
# See BENCH.md for how to write a bot.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="$ROOT/transpiler/rs-output"
export CHOMP_ROOT="$ROOT"

need() {
  command -v "$1" >/dev/null 2>&1 || { echo "bench.sh: '$1' is required but not on PATH" >&2; exit 1; }
}

setup() {
  need python3
  need cargo
  echo "==> generating the Rust engine from the Solidity source"
  python3 -m transpiler src/ --target rust
  echo "==> building (first run compiles the engine and its deps; ~35s on 8 cores, plus crate downloads)"
  cargo build --release --manifest-path "$OUT/Cargo.toml" -p chomp-strategies
  echo "==> ready. Try: ./bench.sh run --bot greedy"
}

# The engine is generated, not committed, so a fresh checkout has to build once.
require_build() {
  if [ ! -x "$OUT/target/release/bench" ]; then
    echo "bench.sh: not built yet — running setup first." >&2
    setup
  fi
}

cmd="${1:-}"
shift || true

case "$cmd" in
  setup) setup ;;
  run)
    require_build
    exec "$OUT/target/release/bench" "$@"
    ;;
  arena)
    require_build
    exec "$OUT/target/release/arena" "$@"
    ;;
  test)
    need cargo
    exec cargo test --release --manifest-path "$OUT/Cargo.toml" -p chomp-strategies "$@"
    ;;
  *)
    sed -n '2,9p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit 2
    ;;
esac
