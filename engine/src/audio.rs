//! Stateful Opus decode plus a bounded SPSC PCM ring. The render path never allocates or locks.
use crate::MysticAudioSetup;
use std::sync::atomic::{
    AtomicU32, AtomicU64,
    Ordering::{Acquire, Relaxed, Release},
};

pub struct MysticOpus {
    decoder: opus::MSDecoder,
    channels: usize,
}
#[no_mangle]
pub unsafe extern "C" fn mystic_opus_new(setup: *const MysticAudioSetup) -> *mut MysticOpus {
    let Some(s) = setup.as_ref() else {
        return std::ptr::null_mut();
    };
    let n = s.channel_count as usize;
    if !(1..=8).contains(&n)
        || s.sample_rate != 48000
        || s.streams == 0
        || s.coupled_streams > s.streams
        || usize::from(s.streams) + usize::from(s.coupled_streams) > 8
    {
        return std::ptr::null_mut();
    }
    match opus::MSDecoder::new(s.sample_rate, s.streams, s.coupled_streams, &s.mapping[..n]) {
        Ok(decoder) => Box::into_raw(Box::new(MysticOpus {
            decoder,
            channels: n,
        })),
        Err(_) => std::ptr::null_mut(),
    }
}
#[no_mangle]
pub unsafe extern "C" fn mystic_opus_decode(
    handle: *mut MysticOpus,
    packet: *const u8,
    length: usize,
    pcm: *mut f32,
    sample_capacity: usize,
    frame_capacity: u32,
) -> i32 {
    let Some(d) = handle.as_mut() else { return -1 };
    let frames = frame_capacity as usize;
    if pcm.is_null()
        || frames == 0
        || frames > 5760
        || sample_capacity < frames * d.channels
        || length > 65536
        || (packet.is_null() && length != 0)
        || (!packet.is_null() && length == 0)
    {
        return -1;
    }
    let input = if packet.is_null() {
        &[]
    } else {
        std::slice::from_raw_parts(packet, length)
    };
    let output = std::slice::from_raw_parts_mut(pcm, frames * d.channels);
    match d.decoder.decode_float(input, output, false) {
        Ok(n) => n as i32,
        Err(_) => -2,
    }
}
#[no_mangle]
pub unsafe extern "C" fn mystic_opus_free(p: *mut MysticOpus) {
    if !p.is_null() {
        drop(Box::from_raw(p));
    }
}

pub struct MysticPCMRing {
    samples: Box<[AtomicU32]>,
    channels: usize,
    capacity: u64,
    max_queued: AtomicU64,
    write: AtomicU64,
    read: AtomicU64,
    gain: AtomicU32,
    current_gain: AtomicU32,
    written: AtomicU64,
    rendered: AtomicU64,
    dropped: AtomicU64,
    underrun: AtomicU64,
}
#[repr(C)]
#[derive(Default)]
pub struct MysticPCMStats {
    pub written_frames: u64,
    pub rendered_frames: u64,
    pub dropped_frames: u64,
    pub underrun_frames: u64,
    pub queued_frames: u32,
}
#[no_mangle]
pub extern "C" fn mystic_pcm_ring_new(capacity: u32, max_queued: u32) -> *mut MysticPCMRing {
    mystic_pcm_ring_new_channels(capacity, max_queued, 2)
}
#[no_mangle]
pub extern "C" fn mystic_pcm_ring_new_channels(
    capacity: u32,
    max_queued: u32,
    channels: u32,
) -> *mut MysticPCMRing {
    if !(128..=65536).contains(&capacity)
        || !capacity.is_power_of_two()
        || max_queued == 0
        || max_queued > capacity
        || !(1..=8).contains(&channels)
    {
        return std::ptr::null_mut();
    }
    Box::into_raw(Box::new(MysticPCMRing {
        samples: (0..capacity * channels)
            .map(|_| AtomicU32::new(0))
            .collect(),
        channels: channels as usize,
        capacity: u64::from(capacity),
        max_queued: AtomicU64::new(u64::from(max_queued)),
        gain: AtomicU32::new(1f32.to_bits()),
        current_gain: AtomicU32::new(1f32.to_bits()),
        write: AtomicU64::new(0),
        read: AtomicU64::new(0),
        written: AtomicU64::new(0),
        rendered: AtomicU64::new(0),
        dropped: AtomicU64::new(0),
        underrun: AtomicU64::new(0),
    }))
}
#[no_mangle]
pub unsafe extern "C" fn mystic_pcm_ring_write(
    p: *mut MysticPCMRing,
    pcm: *const f32,
    frames: u32,
) -> u32 {
    let Some(r) = p.as_ref() else { return 0 };
    if pcm.is_null() || frames > 5760 {
        return 0;
    }
    let write = r.write.load(Relaxed);
    let available = r
        .capacity
        .saturating_sub(write.wrapping_sub(r.read.load(Acquire)));
    let count = u64::from(frames).min(available);
    for i in 0..count {
        let slot = ((write + i) & (r.capacity - 1)) as usize * r.channels;
        for channel in 0..r.channels {
            r.samples[slot + channel].store(
                (*pcm.add(i as usize * r.channels + channel)).to_bits(),
                Relaxed,
            );
        }
    }
    r.write.store(write.wrapping_add(count), Release);
    r.written.fetch_add(count, Relaxed);
    r.dropped.fetch_add(u64::from(frames) - count, Relaxed);
    count as u32
}
#[no_mangle]
pub unsafe extern "C" fn mystic_pcm_ring_read(
    p: *mut MysticPCMRing,
    left: *mut f32,
    right: *mut f32,
    frames: u32,
) -> u32 {
    let planes = [left, right];
    mystic_pcm_ring_read_planar(p, planes.as_ptr(), 2, frames)
}
/// Caller supplies `channels` non-null planes, each holding at least `frames` floats.
/// Fixed-size plane tables and scalar atomics keep the render path allocation/lock free.
#[no_mangle]
pub unsafe extern "C" fn mystic_pcm_ring_read_planar(
    p: *mut MysticPCMRing,
    planes: *const *mut f32,
    channels: u32,
    frames: u32,
) -> u32 {
    if planes.is_null() || !(1..=8).contains(&channels) || frames > 65536 {
        return 0;
    }
    let planes = std::slice::from_raw_parts(planes, channels as usize);
    if planes.iter().any(|plane| plane.is_null()) {
        return 0;
    }
    for &plane in planes {
        std::ptr::write_bytes(plane, 0, frames as usize);
    }
    let Some(r) = p.as_ref() else { return 0 };
    if r.channels != channels as usize {
        return 0;
    }
    let write = r.write.load(Acquire);
    let mut read = r.read.load(Relaxed);
    let mut available = write.wrapping_sub(read);
    let max_queued = r.max_queued.load(Relaxed);
    if available > max_queued {
        let skip = available - max_queued;
        read = read.wrapping_add(skip);
        available = max_queued;
        r.dropped.fetch_add(skip, Relaxed);
    }
    let count = available.min(u64::from(frames));
    let start_gain = f32::from_bits(r.current_gain.load(Relaxed));
    let target_gain = f32::from_bits(r.gain.load(Acquire));
    let ramp = u64::from(frames).min(128).max(1);
    for i in 0..count {
        let gain = if i < ramp {
            start_gain + (target_gain - start_gain) * (i + 1) as f32 / ramp as f32
        } else {
            target_gain
        };
        let slot = ((read + i) & (r.capacity - 1)) as usize * r.channels;
        for (channel, &plane) in planes.iter().enumerate() {
            *plane.add(i as usize) = f32::from_bits(r.samples[slot + channel].load(Relaxed)) * gain;
        }
    }
    r.current_gain.store(target_gain.to_bits(), Relaxed);
    r.read.store(read.wrapping_add(count), Release);
    r.rendered.fetch_add(count, Relaxed);
    r.underrun.fetch_add(u64::from(frames) - count, Relaxed);
    count as u32
}
/// The most frames kept before the oldest are dropped: a device with a long read needs room above
/// the drift trim's line. Ignored past the ring's capacity.
#[no_mangle]
pub unsafe extern "C" fn mystic_pcm_ring_set_max_queued(p: *mut MysticPCMRing, frames: u32) {
    if let Some(r) = p.as_ref() {
        if frames > 0 && u64::from(frames) <= r.capacity {
            r.max_queued.store(u64::from(frames), Relaxed);
        }
    }
}
#[no_mangle]
pub unsafe extern "C" fn mystic_pcm_ring_set_gain(p: *mut MysticPCMRing, gain: f32) {
    if let Some(r) = p.as_ref() {
        let gain = if gain.is_finite() {
            gain.clamp(0.0, 1.0)
        } else {
            0.0
        };
        r.gain.store(gain.to_bits(), Release);
    }
}
#[no_mangle]
pub unsafe extern "C" fn mystic_pcm_ring_stats(p: *const MysticPCMRing) -> MysticPCMStats {
    let Some(r) = p.as_ref() else {
        return MysticPCMStats::default();
    };
    // Read the consumer first: concurrent progress may overestimate, never underflow.
    let read = r.read.load(Acquire);
    let write = r.write.load(Acquire);
    MysticPCMStats {
        written_frames: r.written.load(Relaxed),
        rendered_frames: r.rendered.load(Relaxed),
        dropped_frames: r.dropped.load(Relaxed),
        underrun_frames: r.underrun.load(Relaxed),
        queued_frames: write.wrapping_sub(read).min(r.capacity) as u32,
    }
}
#[no_mangle]
pub unsafe extern "C" fn mystic_pcm_ring_free(p: *mut MysticPCMRing) {
    if !p.is_null() {
        drop(Box::from_raw(p));
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn multichannel_ring_preserves_planes_catchup_gain_and_bounds() {
        unsafe {
            assert!(mystic_pcm_ring_new_channels(128, 128, 0).is_null());
            assert!(mystic_pcm_ring_new_channels(128, 128, 9).is_null());
            for channels in [6usize, 8] {
                let ring = mystic_pcm_ring_new_channels(128, 64, channels as u32);
                let input: Vec<f32> = (0..128 * channels).map(|n| n as f32).collect();
                assert_eq!(mystic_pcm_ring_write(ring, input.as_ptr(), 128), 128);
                let mut planes = vec![vec![-1f32; 80]; channels];
                let pointers: Vec<*mut f32> = planes.iter_mut().map(|p| p.as_mut_ptr()).collect();
                assert_eq!(
                    mystic_pcm_ring_read_planar(ring, pointers.as_ptr(), channels as u32, 80),
                    64
                );
                for channel in 0..channels {
                    for frame in 0..64 {
                        assert_eq!(
                            planes[channel][frame],
                            ((frame + 64) * channels + channel) as f32
                        );
                    }
                    assert!(planes[channel][64..].iter().all(|v| *v == 0.));
                }
                let stats = mystic_pcm_ring_stats(ring);
                assert_eq!(stats.dropped_frames, 64);
                assert_eq!(stats.underrun_frames, 16);
                mystic_pcm_ring_set_gain(ring, 0.);
                mystic_pcm_ring_write(ring, input.as_ptr(), 128);
                mystic_pcm_ring_read_planar(ring, pointers.as_ptr(), channels as u32, 64);
                assert!(planes.iter().all(|plane| plane[63] == 0.));
                mystic_pcm_ring_free(ring);
            }
        }
    }
    #[test]
    fn multichannel_read_rejects_mismatched_or_missing_planes_without_consuming() {
        unsafe {
            let ring = mystic_pcm_ring_new_channels(128, 128, 8);
            let input = [0.25f32; 64];
            mystic_pcm_ring_write(ring, input.as_ptr(), 8);
            let mut l = [1f32; 8];
            let mut r = l;
            assert_eq!(
                mystic_pcm_ring_read(ring, l.as_mut_ptr(), r.as_mut_ptr(), 8),
                0
            );
            assert_eq!(l, [0.; 8]);
            assert_eq!(r, [0.; 8]);
            let pointers = [std::ptr::null_mut(); 8];
            assert_eq!(
                mystic_pcm_ring_read_planar(ring, pointers.as_ptr(), 8, 8),
                0
            );
            assert_eq!(mystic_pcm_ring_stats(ring).queued_frames, 8);
            mystic_pcm_ring_free(ring);
        }
    }
    #[test]
    fn eight_channel_spsc_ordering() {
        use std::sync::Arc;
        unsafe {
            let ring: Arc<MysticPCMRing> =
                Arc::from(Box::from_raw(mystic_pcm_ring_new_channels(1024, 1024, 8)));
            let producer = ring.clone();
            let thread = std::thread::spawn(move || {
                for frame in 0..10000 {
                    let samples: [f32; 8] = std::array::from_fn(|ch| (frame * 8 + ch) as f32);
                    while mystic_pcm_ring_write(
                        Arc::as_ptr(&producer) as *mut _,
                        samples.as_ptr(),
                        1,
                    ) == 0
                    {
                        std::thread::yield_now();
                    }
                }
            });
            let mut planes = [[0f32; 64]; 8];
            let pointers: [*mut f32; 8] = std::array::from_fn(|ch| planes[ch].as_mut_ptr());
            let mut received = 0;
            let deadline = std::time::Instant::now() + std::time::Duration::from_secs(10);
            while received < 10000 {
                assert!(std::time::Instant::now() < deadline);
                let count = mystic_pcm_ring_read_planar(
                    Arc::as_ptr(&ring) as *mut _,
                    pointers.as_ptr(),
                    8,
                    64,
                );
                for frame in 0..count as usize {
                    for channel in 0..8 {
                        assert_eq!(
                            planes[channel][frame],
                            ((received + frame) * 8 + channel) as f32
                        );
                    }
                }
                received += count as usize;
                if count == 0 {
                    std::thread::yield_now();
                }
            }
            thread.join().unwrap();
        }
    }
    #[test]
    fn ring_bounds_catchup_and_zero_fill() {
        unsafe {
            let ring = mystic_pcm_ring_new(128, 64);
            let input: Vec<f32> = (0..256).map(|i| i as f32).collect();
            assert_eq!(mystic_pcm_ring_write(ring, input.as_ptr(), 128), 128);
            assert_eq!(mystic_pcm_ring_write(ring, input.as_ptr(), 1), 0);
            let mut left = [-1.; 80];
            let mut right = [-1.; 80];
            assert_eq!(
                mystic_pcm_ring_read(ring, left.as_mut_ptr(), right.as_mut_ptr(), 80),
                64
            );
            assert_eq!(left[0], 128.);
            assert_eq!(right[0], 129.);
            assert!(left[64..].iter().all(|v| *v == 0.));
            let stats = mystic_pcm_ring_stats(ring);
            assert_eq!(stats.dropped_frames, 65);
            assert_eq!(stats.underrun_frames, 16);
            assert_eq!(stats.queued_frames, 0);
            mystic_pcm_ring_free(ring);
        }
    }
    #[test]
    fn gain_mute_and_spsc_concurrency() {
        use std::sync::Arc;
        unsafe {
            let raw = mystic_pcm_ring_new(128, 128);
            let samples = [1f32; 256];
            let mut l = [0f32; 128];
            let mut r = [0f32; 128];
            mystic_pcm_ring_write(raw, samples.as_ptr(), 128);
            mystic_pcm_ring_set_gain(raw, 0.);
            mystic_pcm_ring_read(raw, l.as_mut_ptr(), r.as_mut_ptr(), 128);
            assert!(l[0] > 0. && l[0] < 1.);
            assert_eq!(l[127], 0.);
            mystic_pcm_ring_write(raw, samples.as_ptr(), 128);
            mystic_pcm_ring_read(raw, l.as_mut_ptr(), r.as_mut_ptr(), 128);
            assert!(l.iter().all(|v| *v == 0.));
            mystic_pcm_ring_free(raw);
            let ring: Arc<MysticPCMRing> =
                Arc::from(Box::from_raw(mystic_pcm_ring_new(1024, 1024)));
            let producer = ring.clone();
            let thread = std::thread::spawn(move || {
                for n in 0..20000 {
                    let pair = [n as f32, -(n as f32)];
                    while mystic_pcm_ring_write(Arc::as_ptr(&producer) as *mut _, pair.as_ptr(), 1)
                        == 0
                    {
                        std::thread::yield_now();
                    }
                }
            });
            let mut received = 0;
            let mut left = [0.; 64];
            let mut right = [0.; 64];
            let deadline = std::time::Instant::now() + std::time::Duration::from_secs(10);
            while received < 20000 {
                assert!(std::time::Instant::now() < deadline, "SPSC ring stalled");
                let count = mystic_pcm_ring_read(
                    Arc::as_ptr(&ring) as *mut _,
                    left.as_mut_ptr(),
                    right.as_mut_ptr(),
                    64,
                );
                for i in 0..count as usize {
                    assert_eq!(left[i], received as f32);
                    assert_eq!(right[i], -(received as f32));
                    received += 1;
                }
                if count == 0 {
                    std::thread::yield_now();
                }
            }
            thread.join().unwrap();
        }
    }
    #[test]
    fn opus_decode_and_loss_concealment() {
        unsafe {
            let setup = MysticAudioSetup {
                channel_count: 2,
                sample_rate: 48000,
                streams: 1,
                coupled_streams: 1,
                mapping: [0, 1, 0, 0, 0, 0, 0, 0],
                ..Default::default()
            };
            let decoder = mystic_opus_new(&setup);
            assert!(!decoder.is_null());
            let mut encoder =
                opus::Encoder::new(48000, opus::Channels::Stereo, opus::Application::LowDelay)
                    .unwrap();
            let tone: Vec<f32> = (0..480)
                .flat_map(|n| {
                    let v = (n as f32 * 0.1).sin() * 0.1;
                    [v, -v]
                })
                .collect();
            let mut packet = [0u8; 4096];
            let n = encoder.encode_float(&tone, &mut packet).unwrap();
            let mut pcm = [0f32; 960];
            assert_eq!(
                mystic_opus_decode(decoder, packet.as_ptr(), n, pcm.as_mut_ptr(), 960, 480),
                480
            );
            assert!(pcm.iter().all(|v| v.is_finite()));
            assert!(pcm.iter().any(|v| v.abs() > 0.001));
            assert_eq!(
                mystic_opus_decode(decoder, std::ptr::null(), 0, pcm.as_mut_ptr(), 960, 480),
                480
            );
            assert_eq!(
                mystic_opus_decode(decoder, packet.as_ptr(), 0, pcm.as_mut_ptr(), 960, 480),
                -1
            );
            assert_eq!(
                mystic_opus_decode(decoder, packet.as_ptr(), n, pcm.as_mut_ptr(), 10, 480),
                -1
            );
            mystic_opus_free(decoder);
        }
    }
}
