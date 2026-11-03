#!/usr/bin/env bash
# Builds the engine's static library for iPhone and iPad (aarch64-apple-ios), where Package.swift
# links it for iOS. Needs Xcode with the iOS SDK, Rust, and CMake for the bundled libopus.
# Groundwork: there is no iOS app yet, and no simulator build.
set -euo pipefail

cd "$(dirname "$0")/../engine"
export CARGO_NET_GIT_FETCH_WITH_CLI="${CARGO_NET_GIT_FETCH_WITH_CLI:-true}"
# The C code (libopus through CMake, ring's assembly) targets the same iOS as Package.swift.
export IPHONEOS_DEPLOYMENT_TARGET="${IPHONEOS_DEPLOYMENT_TARGET:-27.0}"

target=aarch64-apple-ios
rustup target add "$target" >/dev/null
profile=release
[ "${1:-}" = "debug" ] && profile=debug
flags=(--target "$target" --locked)
[ "$profile" = release ] && flags+=(--release)
cargo build "${flags[@]}"

lib="target/$target/$profile/libmystic_ffi.a"
[ -f "$lib" ] || { echo "missing $lib" >&2; exit 1; }
echo "   $(du -h "$lib" | cut -f1) $lib"
