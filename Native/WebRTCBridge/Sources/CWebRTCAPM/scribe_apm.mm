/*
 * scribe_apm.mm — the implementation behind scribe_apm.h.
 *
 * Objective-C++ so that the C++ WebRTC module stays entirely on this side of
 * the header and the rest of Scribe only ever sees plain C. Nothing in here
 * allocates per block: the module owns its own working memory and the caller
 * owns the audio buffers.
 */

#include "include/scribe_apm.h"

#include <string.h>

#include <algorithm>
#include <optional>

#include "api/audio/audio_processing.h"
#include "api/scoped_refptr.h"

namespace {

// Upstream accepts only these rates. Anything else is rejected at construction
// rather than being silently resampled, because a silently resampled reference
// signal produces echo cancellation that fails in ways that are hard to read
// back from the output.
bool IsSupportedSampleRate(int32_t rate) {
    return rate == 8000 || rate == 16000 || rate == 32000 || rate == 48000;
}

bool IsSupportedChannelCount(int32_t channels) {
    // The module's own ceiling. Scribe uses 2 render / 1 capture.
    return channels >= 1 && channels <= 8;
}

size_t FramesPerBlock(int32_t sample_rate_hz) {
    return static_cast<size_t>(sample_rate_hz / 100);
}

}  // namespace

struct ScribeAPM {
    rtc::scoped_refptr<webrtc::AudioProcessing> apm;
    webrtc::StreamConfig render_config;
    webrtc::StreamConfig capture_input_config;
    webrtc::StreamConfig capture_output_config;
    ScribeAPMConfig config;
    int32_t stream_delay_ms;
};

extern "C" {

ScribeAPMConfig scribe_apm_default_config(void) {
    ScribeAPMConfig config;
    memset(&config, 0, sizeof(config));
    // Section 5: stereo render input, mono capture, at 48 kHz.
    config.render_sample_rate_hz = 48000;
    config.render_channels = 2;
    config.capture_sample_rate_hz = 48000;
    config.capture_channels = 1;
    config.echo_canceller_enabled = true;
    config.multi_channel_render = true;
    config.high_pass_filter_enabled = true;
    // Off so that a measured change in the capture signal is attributable to
    // AEC3 and not to a gain stage or a noise gate.
    config.noise_suppression_enabled = false;
    config.gain_controller_enabled = false;
    config.export_linear_aec_output = false;
    return config;
}

ScribeAPM *scribe_apm_create(const ScribeAPMConfig *config, ScribeAPMStatus *out_status) {
    ScribeAPMStatus ignored = ScribeAPMStatusSuccess;
    ScribeAPMStatus &status = out_status != nullptr ? *out_status : ignored;
    status = ScribeAPMStatusSuccess;

    if (config == nullptr) {
        status = ScribeAPMStatusNullArgument;
        return nullptr;
    }
    if (!IsSupportedSampleRate(config->render_sample_rate_hz) ||
        !IsSupportedSampleRate(config->capture_sample_rate_hz)) {
        status = ScribeAPMStatusUnsupportedSampleRate;
        return nullptr;
    }
    if (!IsSupportedChannelCount(config->render_channels) ||
        !IsSupportedChannelCount(config->capture_channels)) {
        status = ScribeAPMStatusUnsupportedChannelCount;
        return nullptr;
    }

    webrtc::AudioProcessing::Config apm_config;
    apm_config.echo_canceller.enabled = config->echo_canceller_enabled;
    apm_config.echo_canceller.mobile_mode = false;
    apm_config.echo_canceller.export_linear_aec_output = config->export_linear_aec_output;
    apm_config.high_pass_filter.enabled = config->high_pass_filter_enabled;
    apm_config.noise_suppression.enabled = config->noise_suppression_enabled;
    // Both generations of the gain controller follow the one AGC switch; leaving
    // either one on would defeat the point of turning AGC off.
    apm_config.gain_controller1.enabled = config->gain_controller_enabled;
    apm_config.gain_controller2.enabled = false;
    apm_config.pipeline.multi_channel_render =
        config->multi_channel_render && config->render_channels > 1;
    apm_config.pipeline.multi_channel_capture = config->capture_channels > 1;

    rtc::scoped_refptr<webrtc::AudioProcessing> apm =
        webrtc::AudioProcessingBuilder().SetConfig(apm_config).Create();
    if (apm == nullptr) {
        status = ScribeAPMStatusCreationFailed;
        return nullptr;
    }

    ScribeAPM *handle = new (std::nothrow) ScribeAPM();
    if (handle == nullptr) {
        status = ScribeAPMStatusCreationFailed;
        return nullptr;
    }

    handle->apm = std::move(apm);
    handle->config = *config;
    handle->render_config = webrtc::StreamConfig(config->render_sample_rate_hz,
                                                 static_cast<size_t>(config->render_channels));
    handle->capture_input_config = webrtc::StreamConfig(config->capture_sample_rate_hz,
                                                        static_cast<size_t>(config->capture_channels));
    handle->capture_output_config = handle->capture_input_config;
    handle->stream_delay_ms = 0;

    if (handle->apm->Initialize() != webrtc::AudioProcessing::kNoError) {
        delete handle;
        status = ScribeAPMStatusCreationFailed;
        return nullptr;
    }
    return handle;
}

void scribe_apm_destroy(ScribeAPM *apm) {
    delete apm;
}

ScribeAPMStatus scribe_apm_analyze_render(ScribeAPM *apm,
                                          const float *const *channels,
                                          size_t channel_count,
                                          size_t frames) {
    if (apm == nullptr || channels == nullptr) {
        return ScribeAPMStatusNullArgument;
    }
    if (channel_count != static_cast<size_t>(apm->config.render_channels)) {
        return ScribeAPMStatusChannelCountMismatch;
    }
    if (frames != FramesPerBlock(apm->config.render_sample_rate_hz)) {
        return ScribeAPMStatusUnexpectedBlockSize;
    }
    for (size_t channel = 0; channel < channel_count; ++channel) {
        if (channels[channel] == nullptr) {
            return ScribeAPMStatusNullArgument;
        }
    }
    if (apm->apm->AnalyzeReverseStream(channels, apm->render_config) !=
        webrtc::AudioProcessing::kNoError) {
        return ScribeAPMStatusProcessingFailed;
    }
    return ScribeAPMStatusSuccess;
}

ScribeAPMStatus scribe_apm_process_capture(ScribeAPM *apm,
                                           const float *const *input,
                                           size_t input_channel_count,
                                           float *const *output,
                                           size_t output_channel_count,
                                           size_t frames) {
    if (apm == nullptr || input == nullptr || output == nullptr) {
        return ScribeAPMStatusNullArgument;
    }
    const size_t expected = static_cast<size_t>(apm->config.capture_channels);
    if (input_channel_count != expected || output_channel_count != expected) {
        return ScribeAPMStatusChannelCountMismatch;
    }
    if (frames != FramesPerBlock(apm->config.capture_sample_rate_hz)) {
        return ScribeAPMStatusUnexpectedBlockSize;
    }
    for (size_t channel = 0; channel < expected; ++channel) {
        if (input[channel] == nullptr || output[channel] == nullptr) {
            return ScribeAPMStatusNullArgument;
        }
    }
    if (apm->apm->ProcessStream(input, apm->capture_input_config,
                                apm->capture_output_config, output) !=
        webrtc::AudioProcessing::kNoError) {
        return ScribeAPMStatusProcessingFailed;
    }
    return ScribeAPMStatusSuccess;
}

ScribeAPMStatus scribe_apm_set_stream_delay_ms(ScribeAPM *apm, int32_t delay_ms) {
    if (apm == nullptr) {
        return ScribeAPMStatusNullArgument;
    }
    if (delay_ms < 0) {
        return ScribeAPMStatusInvalidStreamDelay;
    }
    // Upstream clamps out-of-range values and returns a warning rather than
    // failing. Record what we asked for, and report the clamp as an error so a
    // caller with a nonsensical delay estimate hears about it instead of
    // quietly getting a different alignment than it believes it set.
    const int result = apm->apm->set_stream_delay_ms(static_cast<int>(delay_ms));
    apm->stream_delay_ms = apm->apm->stream_delay_ms();
    if (result != webrtc::AudioProcessing::kNoError) {
        return ScribeAPMStatusInvalidStreamDelay;
    }
    return ScribeAPMStatusSuccess;
}

int32_t scribe_apm_stream_delay_ms(const ScribeAPM *apm) {
    if (apm == nullptr) {
        return -1;
    }
    return apm->stream_delay_ms;
}

ScribeAPMStatus scribe_apm_reset(ScribeAPM *apm) {
    if (apm == nullptr) {
        return ScribeAPMStatusNullArgument;
    }
    if (apm->apm->Initialize() != webrtc::AudioProcessing::kNoError) {
        return ScribeAPMStatusProcessingFailed;
    }
    // Initialize() drops the adapted filter but keeps the declared delay, so
    // re-read rather than assuming either outcome.
    apm->stream_delay_ms = apm->apm->stream_delay_ms();
    return ScribeAPMStatusSuccess;
}

ScribeAPMMetrics scribe_apm_metrics(ScribeAPM *apm) {
    ScribeAPMMetrics metrics;
    memset(&metrics, 0, sizeof(metrics));
    if (apm == nullptr) {
        return metrics;
    }

    const webrtc::AudioProcessingStats stats = apm->apm->GetStatistics();

    if (stats.echo_return_loss.has_value()) {
        metrics.has_echo_return_loss = true;
        metrics.echo_return_loss = *stats.echo_return_loss;
    }
    if (stats.echo_return_loss_enhancement.has_value()) {
        metrics.has_echo_return_loss_enhancement = true;
        metrics.echo_return_loss_enhancement = *stats.echo_return_loss_enhancement;
    }
    if (stats.delay_ms.has_value()) {
        metrics.has_delay_ms = true;
        metrics.delay_ms = *stats.delay_ms;
    }
    if (stats.delay_median_ms.has_value()) {
        metrics.has_delay_median_ms = true;
        metrics.delay_median_ms = *stats.delay_median_ms;
    }
    if (stats.delay_standard_deviation_ms.has_value()) {
        metrics.has_delay_standard_deviation_ms = true;
        metrics.delay_standard_deviation_ms = *stats.delay_standard_deviation_ms;
    }
    if (stats.divergent_filter_fraction.has_value()) {
        metrics.has_divergent_filter_fraction = true;
        metrics.divergent_filter_fraction = *stats.divergent_filter_fraction;
    }
    if (stats.residual_echo_likelihood.has_value()) {
        metrics.has_residual_echo_likelihood = true;
        metrics.residual_echo_likelihood = *stats.residual_echo_likelihood;
    }
    if (stats.residual_echo_likelihood_recent_max.has_value()) {
        metrics.has_residual_echo_likelihood_recent_max = true;
        metrics.residual_echo_likelihood_recent_max =
            *stats.residual_echo_likelihood_recent_max;
    }
    return metrics;
}

size_t scribe_apm_render_block_frames(const ScribeAPM *apm) {
    if (apm == nullptr) {
        return 0;
    }
    return FramesPerBlock(apm->config.render_sample_rate_hz);
}

size_t scribe_apm_capture_block_frames(const ScribeAPM *apm) {
    if (apm == nullptr) {
        return 0;
    }
    return FramesPerBlock(apm->config.capture_sample_rate_hz);
}

const char *scribe_apm_status_description(ScribeAPMStatus status) {
    switch (status) {
        case ScribeAPMStatusSuccess:
            return "ok";
        case ScribeAPMStatusNullArgument:
            return "a required pointer was null";
        case ScribeAPMStatusUnsupportedSampleRate:
            return "sample rate must be 8000, 16000, 32000, or 48000 Hz";
        case ScribeAPMStatusUnsupportedChannelCount:
            return "channel count must be between 1 and 8";
        case ScribeAPMStatusUnexpectedBlockSize:
            return "a block must hold exactly 10 ms of audio per channel";
        case ScribeAPMStatusChannelCountMismatch:
            return "channel count does not match the configured stream";
        case ScribeAPMStatusInvalidStreamDelay:
            return "stream delay is outside the range the module accepts";
        case ScribeAPMStatusCreationFailed:
            return "the audio processing module could not be created";
        case ScribeAPMStatusProcessingFailed:
            return "the audio processing module rejected the block";
    }
    return "unknown status";
}

const char *scribe_apm_upstream_revision(void) {
#if defined(SCRIBE_APM_UPSTREAM_REVISION)
    return SCRIBE_APM_UPSTREAM_REVISION;
#else
    return "unknown (SCRIBE_APM_UPSTREAM_REVISION was not defined at build time)";
#endif
}

}  // extern "C"
