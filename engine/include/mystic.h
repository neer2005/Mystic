/*
 * mystic.h — C ABI over Nightjar's streaming engine, for the Mystic macOS client.
 *
 * Build the library with `cargo build --release -p mystic-ffi` (see engine/README.md) and
 * link `libmystic_ffi.a`. The Swift side imports this header through
 * Sources/CMystic/include/module.modulemap.
 *
 * Threading contract:
 *   - mystic_session_start() BLOCKS until streaming or a stage fails. Call it off the main
 *     thread.
 *   - Video, audio and log callbacks arrive on session-owned threads; a callback may run
 *     concurrently with another. `user` must be safe for that.
 *   - mystic_session_interrupt() is callable from any thread while start blocks.
 *   - mystic_session_free() must not race with a running callback.
 *
 * Panics abort (panic = "abort"), so nothing unwinds across this boundary.
 */

#ifndef MYSTIC_H
#define MYSTIC_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Bump-matched with MYSTIC_ABI_VERSION in lib.rs. The Swift side must refuse a mismatch. */
#define MYSTIC_ABI_VERSION 2

/* Result codes. */
#define MYSTIC_OK 0
#define MYSTIC_ERR_INVALID_ARGUMENT (-1)
#define MYSTIC_ERR_START_FAILED (-2)
#define MYSTIC_ERR_NOT_STARTED (-3)
#define MYSTIC_ERR_BUFFER_TOO_SMALL (-4)
#define MYSTIC_ERR_UNIMPLEMENTED (-5)
#define MYSTIC_ERR_INPUT_FAILED (-6)

/* Stage event kinds passed to MysticCallbacks::stage. */
#define MYSTIC_STAGE_STARTING 0
#define MYSTIC_STAGE_COMPLETE 1
#define MYSTIC_STAGE_FAILED 2

typedef struct MysticSession MysticSession;

typedef struct {
    uint32_t format; /* VIDEO_FORMAT_* */
    int32_t width;
    int32_t height;
    int32_t fps;
    uint8_t chroma_packing;
    int32_t logical_width;
    int32_t logical_height;
    int32_t color_space;
    int32_t color_range;
} MysticVideoSetup;

typedef struct {
    uint8_t channel_count;
    uint16_t channel_mask;
    uint32_t packet_duration_ms;
    uint32_t samples_per_frame;
    uint32_t sample_rate;
    uint8_t streams;
    uint8_t coupled_streams;
    uint8_t mapping[8];
} MysticAudioSetup;

/* Borrowed view of a frame. `data` is valid only during the submit callback. */
typedef struct {
    uint32_t number;
    uint8_t frame_type; /* 0 = P, 1 = IDR */
    uint16_t host_processing_latency; /* 1/10 ms, 0 when the host does not report it */
    uint64_t receive_time_us;
    uint64_t enqueue_time_us;
    uint64_t presentation_time_us;
    uint32_t rtp_timestamp;
    bool hdr_active;
    uint8_t colorspace;
    const uint8_t *data;
    size_t data_len;
    size_t buffer_count; /* per-buffer descriptors are not exposed in ABI v1 */
} MysticFrame;

typedef struct {
    uint8_t kind;
    size_t offset;
    size_t length;
} MysticFrameBuffer;

typedef struct {
    int32_t width;
    int32_t height;
    int32_t fps;
    int32_t bitrate_kbps;
    int32_t packet_size;
    uint32_t supported_video_formats;
    uint32_t video_capabilities;
    uint32_t audio_capabilities;
    uint32_t encryption_flags;
    int32_t color_space;
    int32_t color_range;
    int32_t client_refresh_rate_x100;
    uint8_t channel_count;
    uint16_t channel_mask;
    bool microphone;
    bool haptics_pcm;
    bool experimental_packed_444;
    uint8_t packed444_modes;
    bool pyrowave_records_supported;
    bool pyrowave_row_order;
    bool client_wireless;
    uint8_t remote_input_aes_key[16];
    uint8_t remote_input_aes_iv[16];
} MysticStreamConfig;

typedef struct {
    void *user; /* passed back unchanged; never dereferenced by Rust */

    /* Return 0 to proceed; non-zero fails the video stage with that code. */
    int32_t (*video_setup)(void *user, const MysticVideoSetup *setup);
    void (*video_start)(void *user);
    /* Return 0 for Ok, 1 for NeedIdr. */
    int32_t (*video_submit)(void *user, const MysticFrame *frame);
    void (*video_stop)(void *user);
    void (*video_cleanup)(void *user);

    int32_t (*audio_init)(void *user, const MysticAudioSetup *setup);
    void (*audio_start)(void *user);
    /* packet == NULL or len == 0 means a lost packet: run concealment. */
    void (*audio_play)(void *user, const uint8_t *packet, size_t len);
    void (*audio_stop)(void *user);
    void (*audio_cleanup)(void *user);

    void (*stage)(void *user, int32_t stage, int32_t event, int32_t error);
    void (*connection_started)(void *user);
    void (*connection_terminated)(void *user, int32_t code);
    void (*log)(void *user, const char *message);
} MysticCallbacks;

uint32_t mystic_abi_version(void);

/* Layout the Rust side actually compiled. Compare against sizeof() of the structs above;
 * a mismatch means the header and the library disagree and must not be mixed. */
typedef struct {
    size_t video_setup;
    size_t audio_setup;
    size_t frame;
    size_t frame_buffer;
    size_t stream_config;
    size_t callbacks;
} MysticStructSizes;

MysticStructSizes mystic_struct_sizes(void);

MysticSession *mystic_session_new(void);
void mystic_session_free(MysticSession *handle);

/* Cancels a blocking start. Safe from any thread. */
void mystic_session_interrupt(MysticSession *handle);

/*
 * Blocks until streaming or a stage fails. `address` and `app_version` are NUL-terminated
 * UTF-8; `rtsp_session_url` may be NULL. `error_buffer` receives a NUL-terminated message
 * on failure and may be NULL.
 */
int32_t mystic_session_start(MysticSession *handle,
                            const char *address,
                            const char *app_version,
                            const char *rtsp_session_url,
                            uint32_t server_codec_mode_support,
                            const MysticStreamConfig *config,
                            const MysticCallbacks *callbacks,
                            char *error_buffer,
                            size_t error_capacity);

/* Stops every stream. Idempotent; returns MYSTIC_ERR_NOT_STARTED when nothing ran. */
int32_t mystic_session_stop(MysticSession *handle);

/*
 * Input injection. Non-blocking: events are enqueued and the engine batches delivery.
 * All return MYSTIC_ERR_NOT_STARTED until a session is running.
 * key_code is a Windows virtual-key code.
 */
int32_t mystic_session_mouse_move(MysticSession *handle, int16_t dx, int16_t dy);
int32_t mystic_session_mouse_position(MysticSession *handle, int16_t x, int16_t y,
                                      int16_t width, int16_t height);
int32_t mystic_session_mouse_button(MysticSession *handle, uint8_t button, bool down);
int32_t mystic_session_keyboard(MysticSession *handle, uint16_t key_code, bool down,
                                uint8_t modifiers, uint8_t flags);
int32_t mystic_session_scroll(MysticSession *handle, int8_t clicks);
int32_t mystic_session_high_res_scroll(MysticSession *handle, int16_t amount);
int32_t mystic_session_horizontal_scroll(MysticSession *handle, int16_t amount);
int32_t mystic_session_request_idr(MysticSession *handle);

/* Additive host-control API. Calls block; serialize requests off the UI thread.
 * JSON results are {"ok":true,"value":...} or {"ok":false,"error":"..."}.
 * Free all returned strings with mystic_string_free; never log identity/launch JSON.
 * cancel may run concurrently with a request. Free only after all requests complete.
 */
typedef struct MysticHost MysticHost;
char *mystic_identity_create(void);
void mystic_string_free(char *value);
MysticHost *mystic_host_new(const char *address, uint16_t http_port,
                          const char *identity_json, const char *server_certificate_pem,
                          char *error_buffer, size_t error_capacity);
char *mystic_host_request(const MysticHost *host, const char *operation, const char *request_json);
void mystic_host_cancel(const MysticHost *host);
void mystic_host_free(MysticHost *host);

/* Opus and real-time stereo PCM. Decoder calls must be serialized. No decoder call
 * retains packet or output pointers. Returns decoded frames, or a negative error.
 * A NULL packet means loss concealment; non-NULL empty packets are invalid.
 * The ring has exactly one producer and one consumer. Read allocates/locks nothing;
 * it zero-fills underruns and discards stale backlog above max_queued_frames.
 */
typedef struct MysticOpus MysticOpus;
MysticOpus *mystic_opus_new(const MysticAudioSetup *setup);
int32_t mystic_opus_decode(MysticOpus *decoder, const uint8_t *packet, size_t length,
                          float *pcm, size_t sample_capacity, uint32_t frame_capacity);
void mystic_opus_free(MysticOpus *decoder);
typedef struct MysticPCMRing MysticPCMRing;
typedef struct {
    uint64_t written_frames, rendered_frames, dropped_frames, underrun_frames;
    uint32_t queued_frames;
} MysticPCMStats;
MysticPCMRing *mystic_pcm_ring_new(uint32_t capacity_frames, uint32_t max_queued_frames);
uint32_t mystic_pcm_ring_write(MysticPCMRing *ring, const float *interleaved_stereo, uint32_t frames);
uint32_t mystic_pcm_ring_read(MysticPCMRing *ring, float *left, float *right, uint32_t frames);
void mystic_pcm_ring_set_gain(MysticPCMRing *ring, float gain);
MysticPCMStats mystic_pcm_ring_stats(const MysticPCMRing *ring);
/* Free only after both producer and audio render callback have stopped. */
void mystic_pcm_ring_free(MysticPCMRing *ring);

/* Additive controller APIs. Slots 0..3; full state, triggers 0..255, sticks signed. */
int32_t mystic_session_controller(MysticSession *session, uint8_t slot, uint16_t active_mask,
    uint32_t buttons, uint8_t left_trigger, uint8_t right_trigger,
    int16_t left_x, int16_t left_y, int16_t right_x, int16_t right_y);
int32_t mystic_session_controller_arrival(MysticSession *session, uint8_t slot, uint16_t active_mask);

/* Microphone capture: producer write is lock/allocation free; all other calls are
 * serialized on the session worker. Free after the producer has stopped. */
typedef struct MysticMic MysticMic;
MysticMic *mystic_mic_new(uint32_t max_queued_frames);
void mystic_mic_write(const MysticMic *mic, const float *pcm, uint32_t frames, uint32_t stride);
uint32_t mystic_mic_read(const MysticMic *mic, float *pcm, uint32_t frames);
void mystic_mic_mute(MysticMic *mic, bool muted);
int32_t mystic_mic_encode(MysticMic *mic, const float *pcm, uint32_t frames, uint8_t *packet, size_t capacity);
void mystic_mic_free(MysticMic *mic);
bool mystic_session_microphone_available(const MysticSession *session);
int32_t mystic_session_send_microphone(const MysticSession *session, const uint8_t *packet, size_t length);

/* Reserved for a future ABI; returns MYSTIC_ERR_UNIMPLEMENTED in v1. */
int32_t mystic_frame_buffers(const MysticFrame *frame, MysticFrameBuffer *out, size_t capacity);

#ifdef __cplusplus
}
#endif

#endif /* MYSTIC_H */
