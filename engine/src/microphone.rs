//! Bounded SPSC native-rate mono capture plus worker-owned 48 kHz Opus encoding.
use std::cell::UnsafeCell;
use std::sync::atomic::{AtomicBool, AtomicU32, AtomicU64, Ordering::{Acquire, Release, Relaxed}};
pub struct MysticMic {
    samples: Box<[AtomicU64]>, write: AtomicU64, read: AtomicU64,
    max_queued: u64, epoch:AtomicU32, muted: AtomicBool, encoder: UnsafeCell<opus::Encoder>,
}
#[no_mangle]
pub extern "C" fn mystic_mic_new(max_queued: u32) -> *mut MysticMic {
    if !(960..=32768).contains(&max_queued) { return std::ptr::null_mut(); }
    let Ok(mut encoder)=opus::Encoder::new(48000,opus::Channels::Mono,opus::Application::Voip) else { return std::ptr::null_mut(); };
    if encoder.set_bitrate(opus::Bitrate::Bits(32000)).is_err() { return std::ptr::null_mut(); }
    Box::into_raw(Box::new(MysticMic { samples:(0..65536).map(|_|AtomicU64::new(0)).collect(),
        write:AtomicU64::new(0),read:AtomicU64::new(0),max_queued:u64::from(max_queued),epoch:AtomicU32::new(0),muted:AtomicBool::new(false),encoder:UnsafeCell::new(encoder) }))
}
/// Producer: copies the default input's first channel; never allocates or locks.
#[no_mangle]
pub unsafe extern "C" fn mystic_mic_write(p:*const MysticMic,pcm:*const f32,frames:u32,stride:u32) {
    let Some(m)=p.as_ref() else { return };
    let epoch=m.epoch.load(Acquire);
    if pcm.is_null() || frames>8192 || stride==0 || stride>32 || m.muted.load(Acquire) { return; }
    let write=m.write.load(Relaxed);
    let count=u64::from(frames).min(65536u64.saturating_sub(write.wrapping_sub(m.read.load(Acquire))));
    for i in 0..count {
        let sample=*pcm.add((i*u64::from(stride)) as usize);
        m.samples[((write+i)&65535) as usize].store((u64::from(epoch)<<32) | u64::from(if sample.is_finite() { sample.clamp(-1.0,1.0).to_bits() } else {0}),Relaxed);
    }
    m.write.store(write.wrapping_add(count),Release);
}
/// Consumer: exact blocks only; skip old backlog rather than build capture latency.
#[no_mangle]
pub unsafe extern "C" fn mystic_mic_read(p:*const MysticMic,pcm:*mut f32,frames:u32) -> u32 {
    let Some(m)=p.as_ref() else { return 0 };
    if pcm.is_null() || frames==0 || frames>8192 { return 0; }
    let write=m.write.load(Acquire);let mut read=m.read.load(Relaxed);
    if m.muted.load(Acquire) { m.read.store(write,Release);return 0; }
    if write.wrapping_sub(read)>m.max_queued { read=write.wrapping_sub(m.max_queued);m.read.store(read,Release); }
    if write.wrapping_sub(read)<u64::from(frames) { return 0; }
    let epoch=m.epoch.load(Acquire);
    for i in 0..u64::from(frames) {
        let sample=m.samples[((read+i)&65535) as usize].load(Relaxed);
        if (sample>>32) as u32 != epoch { m.read.store(read.wrapping_add(u64::from(frames)),Release);return 0; }
        *pcm.add(i as usize)=f32::from_bits(sample as u32);
    }
    m.read.store(read.wrapping_add(u64::from(frames)),Release);frames
}
/// Serialized consumer control. A resume never sends PCM retained before mute.
#[no_mangle]
pub unsafe extern "C" fn mystic_mic_mute(p:*mut MysticMic,muted:bool) {
    if let Some(m)=p.as_ref() { m.muted.store(true,Release);m.epoch.fetch_add(1,Release);m.read.store(m.write.load(Acquire),Release);
        let _=(&mut *m.encoder.get()).reset_state();m.muted.store(muted,Release); }
}
/// Worker only; caller supplies exactly 20 ms of mono float PCM and 1275 output bytes.
#[no_mangle]
pub unsafe extern "C" fn mystic_mic_encode(p:*mut MysticMic,pcm:*const f32,frames:u32,out:*mut u8,capacity:usize) -> i32 {
    let Some(m)=p.as_ref() else { return -1 };
    if pcm.is_null() || out.is_null() || frames!=960 || capacity<1275 || m.muted.load(Acquire) { return -1; }
    (&mut *m.encoder.get()).encode_float(std::slice::from_raw_parts(pcm,960),std::slice::from_raw_parts_mut(out,1275)).map(|n|n as i32).unwrap_or(-2)
}
#[no_mangle]
pub unsafe extern "C" fn mystic_mic_free(p:*mut MysticMic) { if !p.is_null() { drop(Box::from_raw(p)); } }
#[cfg(test)] mod tests {
    use super::*;
    #[test] fn bounded_capture_mute_and_opus_round_trip() { unsafe {
        let mic=mystic_mic_new(1920);assert!(!mic.is_null());
        let input=vec![0.25f32;8192];mystic_mic_write(mic,input.as_ptr(),8192,1);
        let mut pcm=[0f32;960];assert_eq!(mystic_mic_read(mic,pcm.as_mut_ptr(),960),960);assert_eq!(pcm[0],0.25);
        let mut packet=[0u8;1275];let n=mystic_mic_encode(mic,pcm.as_ptr(),960,packet.as_mut_ptr(),packet.len());assert!(n>0);
        let mut decoder=opus::Decoder::new(48000,opus::Channels::Mono).unwrap();
        assert_eq!(decoder.decode_float(&packet[..n as usize],&mut pcm,false).unwrap(),960);
        assert_eq!(mystic_mic_encode(mic,pcm.as_ptr(),480,packet.as_mut_ptr(),packet.len()),-1);
        mystic_mic_mute(mic,true);mystic_mic_write(mic,input.as_ptr(),960,1);
        assert_eq!(mystic_mic_read(mic,pcm.as_mut_ptr(),960),0);
        mystic_mic_mute(mic,false);assert_eq!(mystic_mic_read(mic,pcm.as_mut_ptr(),960),0);
        mystic_mic_free(mic);
    }}
}
