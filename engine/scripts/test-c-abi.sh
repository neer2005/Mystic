#!/usr/bin/env bash
# Builds the ABI and drives it from C, so a compiler proves mystic.h matches the Rust
# structs. Works on Linux and macOS.
set -euo pipefail

cd "$(dirname "$0")/.."
export CARGO_NET_GIT_FETCH_WITH_CLI="${CARGO_NET_GIT_FETCH_WITH_CLI:-true}"

echo "== rust ABI tests =="
cargo test

echo "== release static library =="
cargo build --release
lib="target/release/libmystic_ffi.a"
[ -f "$lib" ] || { echo "missing $lib" >&2; exit 1; }
echo "   $(du -h "$lib" | cut -f1) $lib"

echo "== C smoke test =="
out="$(mktemp -d)/c_abi_smoke"
extra=()
if [ "$(uname -s)" = "Darwin" ]; then
  extra=(-framework Security -framework CoreFoundation)
else
  extra=(-ldl)
fi
cc -std=c11 -Wall -Wextra -Iinclude tests/c_abi_smoke.c "$lib" -lpthread -lm "${extra[@]}" -o "$out"
"$out"
