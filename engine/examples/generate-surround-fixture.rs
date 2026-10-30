//! CC0 independent speaker tones. Run from the repo root:
//! cargo run --manifest-path engine/Cargo.toml --example generate-surround-fixture > Tests/MysticStreamTests/Fixtures/audio-surround71.json
fn base64(bytes: &[u8]) -> String {
    const TABLE: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut result = String::new();
    for chunk in bytes.chunks(3) {
        let value = (u32::from(chunk[0]) << 16)
            | (u32::from(*chunk.get(1).unwrap_or(&0)) << 8)
            | u32::from(*chunk.get(2).unwrap_or(&0));
        result.push(TABLE[(value >> 18) as usize] as char);
        result.push(TABLE[((value >> 12) & 63) as usize] as char);
        result.push(if chunk.len() > 1 {
            TABLE[((value >> 6) & 63) as usize] as char
        } else {
            '='
        });
        result.push(if chunk.len() > 2 {
            TABLE[(value & 63) as usize] as char
        } else {
            '='
        });
    }
    result
}
fn main() {
    // Windows speaker order FL FR FC LFE BL BR SL SR. Each Opus stream is independent
    // mono so speaker identity is easy to verify without surround encoder coupling.
    let mapping = [0u8, 1, 2, 3, 4, 5, 6, 7];
    let mut encoder =
        opus::MSEncoder::new(48000, 8, 0, &mapping, opus::Application::LowDelay).unwrap();
    let frequencies: Vec<u32> = (0..8).map(|channel| 250 + 100 * channel).collect();
    let mut packets = Vec::new();
    let mut pcm = [0f32; 240 * 8];
    let mut packet = [0u8; 16384];
    for frame in 0..60 {
        for sample in 0..240 {
            for channel in 0..8 {
                let phase = 2.
                    * std::f64::consts::PI
                    * f64::from(frequencies[channel])
                    * ((frame * 240 + sample) as f64)
                    / 48000.;
                pcm[sample * 8 + channel] = (0.1 * phase.sin()) as f32;
            }
        }
        let count = encoder.encode_float(&pcm, &mut packet).unwrap();
        packets.push(base64(&packet[..count]));
    }
    println!("{}",serde_json::to_string_pretty(&serde_json::json!({
        "sampleRate":48000,"channelCount":8,"channelMask":0x63F,"streams":8,"coupledStreams":0,
        "mapping":mapping,"samplesPerFrame":240,"packetDurationMs":5,"frequencies":frequencies,"packets":packets
    })).unwrap());
}
