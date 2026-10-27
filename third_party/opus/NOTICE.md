# Opus audio decoding

The engine statically links libopus through `opus` 0.4.0 (MIT license choice) and
`opusic-sys` 0.7.6 (BSD-3-Clause, bundled libopus source). Versions/checksums are
pinned in engine/Cargo.lock. No Homebrew libopus installation is needed.

Sources:
- https://github.com/SpaceManiac/opus-rs
- https://github.com/DoumanAsh/opusic-sys
- https://opus-codec.org/

The accompanying license files are copied into the local app's Resources folder.
