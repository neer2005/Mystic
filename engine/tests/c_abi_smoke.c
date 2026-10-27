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

    mystic_session_free(handle);
    mystic_session_free(NULL); /* documented no-op */
    printf("  ok: free(NULL) is a no-op\n");

    printf(failures == 0 ? "PASS\n" : "FAILED (%d)\n", failures);
    return failures == 0 ? 0 : 1;
}
