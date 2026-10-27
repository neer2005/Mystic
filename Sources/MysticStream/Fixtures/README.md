# Synthetic codec probe fixtures

These 64×64, one-frame elementary streams were generated for Mystic from FFmpeg's
synthetic `testsrc2` pattern. They contain no captured or third-party video. The
fixture data is dedicated to the public domain under CC0-1.0:
https://creativecommons.org/publicdomain/zero/1.0/

Regenerate from the repository root:

    python3 scripts/generate-video-fixtures.py /path/to/ffmpeg

Generation used FFmpeg 7.1 with libx264, libx265, and libaom-av1 (the temporary
imageio-ffmpeg 0.6.0 macOS arm64 distribution). No FFmpeg runtime is linked into
Mystic. Encoder versions may produce different valid bytes when regenerating.

Each `.bin` is one access unit. H.264 and HEVC use Annex B framing; AV1 uses
low-overhead, size-delimited OBUs. Names ending in `444` preserve full chroma.
Names containing `10` use 10-bit BT.2020 / PQ; other fixtures use 8-bit BT.709.
HEVC HDR fixtures also contain mastering-display and content-light SEI messages.

The streams are packaged with the library so capability checks exercise actual
hardware-required decoding and display-layer conversion for each profile. A
successful 64×64 probe is not a promise about maximum resolution or frame rate.
