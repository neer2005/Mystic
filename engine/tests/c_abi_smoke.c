/*
 * ABI smoke test driven from C, so a compiler checks that mystic.h and the Rust structs
 * agree. Run by `engine/scripts/test-c-abi.sh`.
 */
#include <assert.h>
#include <stdio.h>
#include <string.h>

#include "mystic.h"

static int failures;

#define CHECK(condition, what)                                                     \
    do {                                                                           \
        if (!(condition)) {                                                        \
            printf("  FAIL: %s\n", (what));                                        \
            failures++;                                                            \
        } else {                                                                   \
            printf("  ok: %s\n", (what));                                          \
        }                                                                          \
    } while (0)

int main(void) {
    printf("mystic C ABI smoke test\n");

    CHECK(mystic_abi_version() == MYSTIC_ABI_VERSION, "header and library agree on ABI version");

    /* Every struct the ABI passes must match the layout Rust compiled: compare the header's
     * sizeof() against the sizes the library reports, rather than trusting a constant. */
    MysticStructSizes sizes = mystic_struct_sizes();
    printf("  layout: video_setup=%zu audio_setup=%zu frame=%zu stream_config=%zu callbacks=%zu\n",
           sizes.video_setup, sizes.audio_setup, sizes.frame, sizes.stream_config,
           sizes.callbacks);
    CHECK(sizes.video_setup == sizeof(MysticVideoSetup), "MysticVideoSetup layout matches Rust");
    CHECK(sizes.audio_setup == sizeof(MysticAudioSetup), "MysticAudioSetup layout matches Rust");
    CHECK(sizes.frame == sizeof(MysticFrame), "MysticFrame layout matches Rust");
    CHECK(sizes.frame_buffer == sizeof(MysticFrameBuffer), "MysticFrameBuffer layout matches Rust");
    CHECK(sizes.stream_config == sizeof(MysticStreamConfig), "MysticStreamConfig layout matches Rust");
    CHECK(sizes.callbacks == sizeof(MysticCallbacks), "MysticCallbacks layout matches Rust");

    MysticSession *handle = mystic_session_new();
    CHECK(handle != NULL, "handle allocation");

    char error[256];
    memset(error, 0, sizeof error);
    int32_t code = mystic_session_start(handle, NULL, NULL, NULL, 0, NULL, NULL, error,
                                        sizeof error);
    CHECK(code == MYSTIC_ERR_INVALID_ARGUMENT, "null arguments are rejected");
    CHECK(strlen(error) > 0, "a failure writes an error message");

    CHECK(mystic_session_stop(handle) == MYSTIC_ERR_NOT_STARTED, "stop before start reports NOT_STARTED");

    /* Input before a session exists must be refused, not queued or crashed. */
    CHECK(mystic_session_mouse_move(handle, 4, -3) == MYSTIC_ERR_NOT_STARTED,
          "mouse move before start is refused");
    CHECK(mystic_session_mouse_position(handle, 10, 20, 1920, 1080) == MYSTIC_ERR_NOT_STARTED,
          "absolute mouse position before start is refused");
    CHECK(mystic_session_mouse_button(handle, 1, true) == MYSTIC_ERR_NOT_STARTED,
          "mouse button before start is refused");
    CHECK(mystic_session_keyboard(handle, 0x41, true, 0, 0) == MYSTIC_ERR_NOT_STARTED,
          "keyboard before start is refused");
    CHECK(mystic_session_scroll(handle, 1) == MYSTIC_ERR_NOT_STARTED,
          "scroll before start is refused");
    CHECK(mystic_session_high_res_scroll(handle, 120) == MYSTIC_ERR_NOT_STARTED,
          "high-resolution scroll before start is refused");
    CHECK(mystic_session_request_idr(handle) == MYSTIC_ERR_NOT_STARTED,
          "IDR request before start is refused");
    CHECK(mystic_session_mouse_button(NULL, 1, true) == MYSTIC_ERR_INVALID_ARGUMENT,
          "input on a null handle is rejected");

    /* The path that matters: a full start attempt with every struct populated. Nothing is
     * listening, so it must fail rather than hang or abort. */
    MysticStreamConfig config;
    memset(&config, 0, sizeof config);
    config.width = 1920;
    config.height = 1080;
    config.fps = 60;
    config.bitrate_kbps = 20000;
    config.packet_size = 1392;
    config.supported_video_formats = 0x00000001u;
    config.color_space = 1;
    config.color_range = 1;
    config.channel_count = 2;
    config.channel_mask = 0x3;

    MysticCallbacks callbacks;
    memset(&callbacks, 0, sizeof callbacks);

    memset(error, 0, sizeof error);
    /* A nonzero codec-mode value so the engine gets past its argument validation and we
     * exercise the real connect path, which must fail fast with nothing listening. */
    code = mystic_session_start(handle, "127.0.0.1", "7.1.431.-1", NULL, 0x00000001u, &config,
                                &callbacks, error, sizeof error);
    CHECK(code == MYSTIC_ERR_START_FAILED, "start against a dead address fails with START_FAILED");
    CHECK(strlen(error) > 0, "start failure explains itself");
    printf("  message: %s\n", error);

    CHECK(mystic_session_stop(handle) == MYSTIC_ERR_NOT_STARTED, "a failed start leaves the handle reusable");

    /* New host-control symbols share the same C ownership contract. */
    char *identity = mystic_identity_create();
    CHECK(identity != NULL, "host identity result is allocated");
    CHECK(identity && strstr(identity, "\"ok\":true"), "host identity generation succeeds");
    mystic_string_free(identity);
    mystic_string_free(NULL);
    char *host_error = mystic_host_request(NULL, NULL, NULL);
    CHECK(host_error && strstr(host_error, "\"ok\":false"), "null host request returns structured error");
    mystic_string_free(host_error);
    mystic_host_cancel(NULL);
    mystic_host_free(NULL);

    MysticAudioSetup audio_setup;
    memset(&audio_setup, 0, sizeof audio_setup);
    audio_setup.channel_count = 2;
    audio_setup.channel_mask = 3;
    audio_setup.sample_rate = 48000;
    audio_setup.samples_per_frame = 240;
    audio_setup.packet_duration_ms = 5;
    audio_setup.streams = 1;
    audio_setup.coupled_streams = 1;
    audio_setup.mapping[0] = 0;
    audio_setup.mapping[1] = 1;
    MysticOpus *opus = mystic_opus_new(&audio_setup);
    CHECK(opus != NULL, "Opus stereo decoder is created through C");
    float pcm[480];
    CHECK(mystic_opus_decode(opus, NULL, 0, pcm, 480, 240) == 240, "Opus conceals a missing packet");
    CHECK(mystic_opus_decode(opus, NULL, 0, pcm, 10, 240) < 0, "Opus rejects undersized output storage");
    mystic_opus_free(opus);
    mystic_opus_free(NULL);
    MysticPCMRing *ring = mystic_pcm_ring_new(128, 64);
    const float stereo[] = {1, 2, 3, 4, 5, 6, 7, 8};
    float left[8], right[8];
    CHECK(ring != NULL, "PCM ring is created through C");
    CHECK(mystic_pcm_ring_write(ring, stereo, 4) == 4, "PCM ring accepts stereo frames");
    CHECK(mystic_pcm_ring_read(ring, left, right, 8) == 4, "PCM ring returns actual available frames");
    CHECK(left[0] == 1 && right[0] == 2 && left[3] == 7 && right[3] == 8 && left[7] == 0,
          "PCM ring preserves channel order and zero-fills underruns");
    MysticPCMStats stats = mystic_pcm_ring_stats(ring);
    CHECK(stats.rendered_frames == 4 && stats.underrun_frames == 4 && stats.queued_frames == 0,
          "PCM statistics cross the ABI correctly");
    mystic_pcm_ring_set_gain(ring, 0);
    mystic_pcm_ring_free(ring);
    mystic_pcm_ring_free(NULL);

    mystic_session_free(handle);
    mystic_session_free(NULL); /* documented no-op */
    printf("  ok: free(NULL) is a no-op\n");

    printf(failures == 0 ? "PASS\n" : "FAILED (%d)\n", failures);
    return failures == 0 ? 0 : 1;
}
