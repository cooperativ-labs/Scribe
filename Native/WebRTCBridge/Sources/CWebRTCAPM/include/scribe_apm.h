/*
 * scribe_apm.h — the whole of Scribe's contact surface with WebRTC.
 *
 * The pinned WebRTC Audio Processing Module is a large C++ library with a
 * template-heavy header set and its own reference-counting conventions. Rather
 * than let that spread through the app, everything Scribe needs is expressed
 * here as plain C: construct, configure, analyze a render block, process a
 * capture block, set the stream delay, reset, read metrics.
 *
 * All audio is deinterleaved 32-bit float, one pointer per channel, and every
 * call moves exactly one 10 ms block. At 48 kHz that is 480 frames per channel,
 * which is what IMPLEMENTATION_PLAN.md section 5 requires.
 *
 * Threading: an instance is not thread-safe. The render and capture calls may
 * be made from different threads only if the caller serializes them; the
 * upstream module makes the same promise. Scribe drives it from one serial
 * DSP queue.
 */

#ifndef SCRIBE_APM_H
#define SCRIBE_APM_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/** The number of frames in one 10 ms block at the given rate. */
#define SCRIBE_APM_FRAMES_PER_BLOCK(sample_rate_hz) ((size_t)((sample_rate_hz) / 100))

/*
 * Result of every fallible call. Zero is success; nothing else is.
 *
 * Declared with a fixed underlying type and closed extensibility so that Swift
 * imports it as a plain Swift enum with a stable set of cases, rather than as a
 * raw integer whose values have to be compared by hand.
 */
typedef enum __attribute__((enum_extensibility(closed))) ScribeAPMStatus : int32_t ScribeAPMStatus;
enum ScribeAPMStatus : int32_t {
    ScribeAPMStatusSuccess = 0,
    /** A required pointer was null. */
    ScribeAPMStatusNullArgument = 1,
    /** A sample rate the module does not accept (8k, 16k, 32k, 48k only). */
    ScribeAPMStatusUnsupportedSampleRate = 2,
    /** A channel count outside the range the module accepts. */
    ScribeAPMStatusUnsupportedChannelCount = 3,
    /** The frame count was not exactly one 10 ms block for the stream's rate. */
    ScribeAPMStatusUnexpectedBlockSize = 4,
    /** The channel count did not match the one the instance was configured for. */
    ScribeAPMStatusChannelCountMismatch = 5,
    /** A stream delay outside the range the module accepts. */
    ScribeAPMStatusInvalidStreamDelay = 6,
    /** The module could not be constructed. */
    ScribeAPMStatusCreationFailed = 7,
    /** The module returned an error code of its own; see the description. */
    ScribeAPMStatusProcessingFailed = 8
};

/**
 * Configuration fixed at construction time.
 *
 * Defaults come from scribe_apm_default_config(): stereo render input, mono
 * capture, AEC3 on, and automatic gain control and noise suppression off, so
 * that measured echo reduction is attributable to AEC3 alone.
 */
typedef struct ScribeAPMConfig {
    /** Render (far-end / system playback) sample rate. Default 48000. */
    int32_t render_sample_rate_hz;
    /** Render channel count. Default 2. */
    int32_t render_channels;
    /** Capture (near-end / microphone) sample rate. Default 48000. */
    int32_t capture_sample_rate_hz;
    /** Capture channel count. Default 1. */
    int32_t capture_channels;

    /** AEC3. Default true; this is the reason the module is here at all. */
    bool echo_canceller_enabled;
    /**
     * Let AEC3 model each render channel separately instead of downmixing.
     * Default true when render_channels > 1. Costs CPU; matters when the two
     * playback channels carry materially different signals.
     */
    bool multi_channel_render;
    /** High-pass filter on the capture path. Default true, as AEC3 expects. */
    bool high_pass_filter_enabled;

    /** Noise suppression. Default false; see section 5. */
    bool noise_suppression_enabled;
    /** Automatic gain control. Default false; see section 5. */
    bool gain_controller_enabled;

    /**
     * Ask AEC3 for the linear filter output as well. Default false. Only
     * useful for diagnostics; it does not change the processed capture signal.
     */
    bool export_linear_aec_output;
} ScribeAPMConfig;

/**
 * A snapshot of the module's echo metrics.
 *
 * Every field is optional upstream, so each value is paired with a has_ flag.
 * When a flag is false the value is unspecified and must not be read. Metrics
 * only become meaningful once the adaptive filter has converged.
 */
typedef struct ScribeAPMMetrics {
    /** ERL = 10*log10(far power / echo power), in dB. */
    bool has_echo_return_loss;
    double echo_return_loss;
    /** ERLE = 10*log10(echo power / output power), in dB. The headline number. */
    bool has_echo_return_loss_enhancement;
    double echo_return_loss_enhancement;
    /** The AEC's instantaneous delay estimate, in milliseconds. */
    bool has_delay_ms;
    int32_t delay_ms;
    /** Median delay over the aggregation window, in milliseconds. */
    bool has_delay_median_ms;
    int32_t delay_median_ms;
    /** Standard deviation of the delay estimate, in milliseconds. */
    bool has_delay_standard_deviation_ms;
    int32_t delay_standard_deviation_ms;
    /** Fraction of the window in which the linear filter diverged, 0...1. */
    bool has_divergent_filter_fraction;
    double divergent_filter_fraction;
    /** Residual echo likelihood, 0...1. */
    bool has_residual_echo_likelihood;
    double residual_echo_likelihood;
    /** Highest residual echo likelihood over the recent window, 0...1. */
    bool has_residual_echo_likelihood_recent_max;
    double residual_echo_likelihood_recent_max;
} ScribeAPMMetrics;

/** Opaque handle. Create with scribe_apm_create, release with scribe_apm_destroy. */
typedef struct ScribeAPM ScribeAPM;

/** The documented defaults described on ScribeAPMConfig. */
ScribeAPMConfig scribe_apm_default_config(void);

/**
 * Construct a module.
 *
 * Returns NULL on failure and, when out_status is non-null, writes the reason
 * there. On success the caller owns the handle and must call
 * scribe_apm_destroy exactly once.
 */
ScribeAPM *scribe_apm_create(const ScribeAPMConfig *config, ScribeAPMStatus *out_status);

/** Release a module. Passing NULL is a no-op. */
void scribe_apm_destroy(ScribeAPM *apm);

/**
 * Feed one 10 ms block of far-end audio down the render path.
 *
 * Must be called for the render block that corresponds to a capture block
 * before that capture block is processed. `channels` holds `channel_count`
 * pointers, each to `frames` floats.
 */
ScribeAPMStatus scribe_apm_analyze_render(ScribeAPM *apm,
                                          const float *const *channels,
                                          size_t channel_count,
                                          size_t frames);

/**
 * Process one 10 ms block of near-end audio and write the cleaned block out.
 *
 * `input` and `output` may point at the same buffers. Output channel count must
 * equal the configured capture channel count.
 */
ScribeAPMStatus scribe_apm_process_capture(ScribeAPM *apm,
                                           const float *const *input,
                                           size_t input_channel_count,
                                           float *const *output,
                                           size_t output_channel_count,
                                           size_t frames);

/**
 * Declare the delay, in milliseconds, between a render block being analyzed and
 * the capture block that contains its echo.
 *
 * This is an acoustic property of the signal being processed. In the offline
 * pipeline it is derived from the reconstructed timeline, never from how long a
 * processing call happened to take.
 */
ScribeAPMStatus scribe_apm_set_stream_delay_ms(ScribeAPM *apm, int32_t delay_ms);

/** The delay currently in effect, or -1 if `apm` is null. */
int32_t scribe_apm_stream_delay_ms(const ScribeAPM *apm);

/**
 * Return the module to its initial state, discarding the adapted filter.
 *
 * Use this at a documented discontinuity — a device change, an output route
 * change, a gap in capture — where the echo path is known to have changed and
 * reconvergence is preferable to adapting from a stale filter.
 *
 * The stream delay declared before the reset survives it. That is upstream's
 * behaviour and this bridge does not invent a different one; a caller whose
 * discontinuity also changed the delay must declare the new value itself.
 */
ScribeAPMStatus scribe_apm_reset(ScribeAPM *apm);

/** Read the current metrics. Returns an all-absent snapshot if `apm` is null. */
ScribeAPMMetrics scribe_apm_metrics(ScribeAPM *apm);

/** Frames in one 10 ms render block for this instance, or 0 if `apm` is null. */
size_t scribe_apm_render_block_frames(const ScribeAPM *apm);

/** Frames in one 10 ms capture block for this instance, or 0 if `apm` is null. */
size_t scribe_apm_capture_block_frames(const ScribeAPM *apm);

/** A short human-readable description of a status, never null. */
const char *scribe_apm_status_description(ScribeAPMStatus status);

/**
 * The exact upstream release this bridge was built against, for example
 * "webrtc-audio-processing 2.1 (846fe90a289f58b7c9303a635142aa2c7caa93e5, WebRTC M131)".
 *
 * Provenance a build can print. It comes from compile-time defines set by
 * Package.swift out of Vendor/webrtc-apm.lock, so it cannot drift away from
 * what was actually linked.
 */
const char *scribe_apm_upstream_revision(void);

#ifdef __cplusplus
}  /* extern "C" */
#endif

#endif /* SCRIBE_APM_H */
