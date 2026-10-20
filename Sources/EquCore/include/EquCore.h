// EquCore.h — C interface of the EquAudio real-time DSP engine.
//
// Threading model
// ---------------
// * "Control" functions (create/destroy/prepare/reset, recording_prepare) allocate or free memory.
//   They must never run concurrently with processing (stop the IOProc first).
// * Parameter setters/getters, meters and the recording reader are lock-free with respect to the
//   audio thread and may be called from any non-audio thread at any time. Setters that need heavy
//   computation (graphic-EQ solver, auto headroom) do it on the caller's thread, serialised by an
//   internal mutex that the audio thread never touches.
// * equ_engine_process() and equ_engine_ioproc() are real-time safe: no allocation, no locks, no
//   system calls, no Objective-C/Swift runtime.
//
// Signal chain (per stereo frame)
// -------------------------------
//   input -> [input meters] -> preamp (incl. auto headroom) -> subsonic HPF -> 10-band graphic EQ
//   -> bass boost (low shelf) -> sub-bass (bell) -> bass harmonics (psychoacoustic bass)
//   -> clarity (presence bell + mud cut) -> treble (high shelf) -> loudness compensation (shelves)
//   -> stereo width (M/S, optional bass-mono) -> crossfeed (bs2b-style) -> output gain
//   -> true-peak look-ahead limiter -> safety clipper -> bypass crossfade (dry path delay-matched)
//   -> [output meters] -> device / recording ring.

#ifndef EQUCORE_H
#define EQUCORE_H

#include <stdint.h>
#include <stdbool.h>
#include <CoreFoundation/CoreFoundation.h>
#include <CoreAudio/CoreAudioTypes.h>
#include <CoreAudio/AudioHardware.h>

CF_ASSUME_NONNULL_BEGIN

#ifdef __cplusplus
extern "C" {
#endif

#define EQU_EQ_BAND_COUNT 10

typedef struct EquEngine EquEngine;

// MARK: - Parameters

/// Every user-facing processing parameter. Values are in the natural unit given by EquParamInfo
/// (dB, Hz, ms, fractions for percentages, 0/1 for toggles). Setters validate and clamp.
typedef CF_CLOSED_ENUM(uint32_t, EquParam) {
    EquParamBypass = 0,            // toggle, default 0. Delay-matched, click-free A/B crossfade.
    EquParamPreampDB,              // -24 ... +12 dB, default 0
    EquParamAutoHeadroom,          // toggle, default 1. Subtracts the largest static boost of the tone curve.
    EquParamEQEnabled,             // toggle, default 1
    EquParamEQBand0,               // 31.25 Hz   -12 ... +12 dB, default 0 (bands are contiguous IDs)
    EquParamEQBand1,               // 62.5 Hz
    EquParamEQBand2,               // 125 Hz
    EquParamEQBand3,               // 250 Hz
    EquParamEQBand4,               // 500 Hz
    EquParamEQBand5,               // 1 kHz
    EquParamEQBand6,               // 2 kHz
    EquParamEQBand7,               // 4 kHz
    EquParamEQBand8,               // 8 kHz
    EquParamEQBand9,               // 16 kHz
    EquParamBassBoostDB,           // 0 ... +12 dB, default 0. Low shelf.
    EquParamSubBassDB,             // 0 ... +12 dB, default 0. Bell near 45 Hz + subsonic protection.
    EquParamBassHarmonics,         // 0 ... 1, default 0. Psychoacoustic bass for small speakers.
    EquParamTrebleDB,              // -9 ... +9 dB, default 0. High shelf.
    EquParamClarity,               // 0 ... 1, default 0. Presence lift + mild low-mid (mud) cut.
    EquParamLoudness,              // 0 ... 1, default 0. Level-dependent loudness compensation.
    EquParamStereoWidth,           // 0 ... 2, default 1 (0 = mono, 2 = 200% side level)
    EquParamBassMono,              // toggle, default 0. Removes side signal below ~120 Hz.
    EquParamCrossfeedEnabled,      // toggle, default 0
    EquParamCrossfeedCutoffHz,     // 300 ... 2000 Hz, default 700
    EquParamCrossfeedFeedDB,       // 1 ... 15 dB, default 4.5 (attenuation of the cross-fed signal)
    EquParamOutputGainDB,          // -24 ... +12 dB, default 0
    EquParamLimiterEnabled,        // toggle, default 1
    EquParamLimiterCeilingDB,      // -12 ... 0 dBFS, default -1
    EquParamLimiterReleaseMS,      // 10 ... 1000 ms, default 150
    EquParamLimiterTruePeak,       // toggle, default 1. 4x oversampled inter-sample peak detection.
    EquParamReverbMix,             // 0 ... 1, default 0. Stereo reverb level (bass below ~200 Hz stays dry).
    EquParamReverbSize,            // 0 ... 1, default 0.5. Room size / decay time.
    EquParamReverbDamping,         // 0 ... 1, default 0.5. High-frequency absorption in the tail.
    EquParamSpatial,               // 0 ... 1, default 0. 3D spatial: wider highs (mono-safe) + early reflections.
    EquParamDeepBass,              // 0 ... 1, default 0. Octave-down sub-bass synthesis tracking the 40-130 Hz band (mono).
    EquParamVoiceGainDB,           // -40 ... +12 dB, default 0. Level of the optional voice (microphone) input in the mix.
    EquParamVoiceMute,             // toggle, default 0. Mutes the voice input (click-free).
    EquParamVoiceDuck,             // 0 ... 1, default 0. Lowers the music by up to 12 dB while the voice is active.
    EquParamCount
};

typedef struct EquParamInfo {
    // String fields are static storage and non-NULL after a successful equ_param_info(); they are
    // declared nullable so the struct can be zero-initialised from Swift.
    const char *_Nullable identifier;   // stable key for presets/settings, e.g. "eq_1k", "bass_boost_db"
    const char *_Nullable displayName;  // e.g. "Bass Boost"
    const char *_Nullable unit;         // display unit: "dB", "Hz", "ms", "%", "" (toggles)
    float minValue;           // in stored units
    float maxValue;
    float defaultValue;
    float displayScale;       // multiply stored value by this for display (100 for "%" parameters, else 1)
    bool isToggle;            // value is 0 or 1
} EquParamInfo;

/// Fills `outInfo` for a parameter. Returns false for an invalid ID.
bool equ_param_info(EquParam param, EquParamInfo *outInfo);

/// Returns the validated value: NaN/Inf -> default, clamped to [min, max], toggles -> 0/1.
float equ_param_validate(EquParam param, float value);

/// Looks up a parameter by its stable identifier. Returns false if unknown.
bool equ_param_from_identifier(const char *identifier, EquParam *outParam);

/// Center frequency (Hz) of a graphic EQ band (0 ... 9): 31.25 * 2^band.
double equ_eq_band_frequency(uint32_t band);

// MARK: - Engine lifecycle (control thread only)

/// Returns NULL only if memory allocation fails.
EquEngine *_Nullable equ_engine_create(void);
void equ_engine_destroy(EquEngine *_Nullable engine);

/// Configures the engine for a sample rate (8 kHz ... 384 kHz) and the largest expected block.
/// Larger blocks are processed in chunks, so maxFrames is a performance hint, not a hard limit.
/// Allocates; resets all DSP state. Returns false for invalid arguments.
bool equ_engine_prepare(EquEngine *engine, double sampleRate, uint32_t maxFrames);

/// Clears filter states, delay lines, limiter and meters. Must not run concurrently with processing.
void equ_engine_reset(EquEngine *engine);

double equ_engine_sample_rate(const EquEngine *engine);

/// Total processing latency in frames (limiter look-ahead + true-peak interpolator delay).
/// Constant for a given sample rate; the bypassed (dry) path is delayed by the same amount.
uint32_t equ_engine_latency_frames(const EquEngine *engine);

// MARK: - Parameters (any thread, lock-free w.r.t. audio)

void equ_engine_set_param(EquEngine *engine, EquParam param, float value);
float equ_engine_get_param(const EquEngine *engine, EquParam param);

/// Listening level hint for loudness compensation: the output device's volume in dB (<= 0),
/// or `known = false` if the device has no readable volume control.
void equ_engine_set_host_volume_db(EquEngine *engine, float volumeDB, bool known);

/// When true the engine still processes, meters and records, but writes silence to the device
/// (used by the self-test so verification does not have to be audible).
void equ_engine_set_output_muted(EquEngine *engine, bool muted);

/// Currently applied automatic headroom (dB, <= 0) derived from the tone curve.
float equ_engine_auto_headroom_db(const EquEngine *engine);

enum {
    EquResponseEQ       = 1u << 0,  // graphic EQ only (as solved/applied, i.e. the real curve)
    EquResponseTone     = 1u << 1,  // bass, sub-bass, clarity, treble, loudness, subsonic filter
    EquResponseGain     = 1u << 2,  // preamp, auto headroom, output gain
    EquResponseAll      = EquResponseEQ | EquResponseTone | EquResponseGain
};

/// Static magnitude response in dB of the selected stages for the *target* parameter values at the
/// current sample rate (excludes dynamics, width and crossfeed). Not real-time; for UI curves/tests.
void equ_engine_response_db(const EquEngine *engine, const float *frequenciesHz, float *outDB,
                            uint32_t count, uint32_t stages);

/// The per-band filter gains (dB) the graphic-EQ solver currently applies for the slider settings.
void equ_engine_eq_filter_gains(const EquEngine *engine, float outGainsDB[EQU_EQ_BAND_COUNT]);

// MARK: - Processing (real-time safe)

/// Processes planar stereo. In-place operation (inL == outL, inR == outR) is allowed.
void equ_engine_process(EquEngine *engine, const float *inL, const float *inR,
                        float *outL, float *outR, uint32_t frames);

/// As equ_engine_process, plus an optional mono voice signal (NULL = none) that is mixed into both channels
/// after the music chain and before the limiter (see EquParamVoiceGainDB / VoiceMute / VoiceDuck).
void equ_engine_process_voice(EquEngine *engine, const float *inL, const float *inR, const float *_Nullable voice,
                              float *outL, float *outR, uint32_t frames);

/// Where the tap stream is in the aggregate device's input buffer list and where the stereo output
/// channels are in its output buffer list. Buffers are interleaved float32 (HAL IOProc format).
typedef struct EquIOLayout {
    uint32_t inputBuffer;          // index of the tap's buffer in inInputData
    uint32_t outputLeftBuffer;     // index of the buffer holding the left output channel
    uint32_t outputLeftChannel;    // channel offset of left inside that interleaved buffer
    uint32_t outputRightBuffer;
    uint32_t outputRightChannel;
    // Optional mirror: the same processed stereo signal is also written to a second sub-device of
    // the aggregate (e.g. a loopback device such as BlackHole that a screen recorder can capture).
    // Ignored unless mirrorEnabled. Not affected by equ_engine_set_output_muted.
    bool mirrorEnabled;
    uint32_t mirrorLeftBuffer;
    uint32_t mirrorLeftChannel;
    uint32_t mirrorRightBuffer;
    uint32_t mirrorRightChannel;
    // Optional voice input: one channel of an input stream (e.g. a microphone sub-device of the aggregate)
    // mixed into the output after the music chain and before the limiter. Ignored unless voiceEnabled.
    bool voiceEnabled;
    uint32_t voiceBuffer;          // index of the voice stream in inInputData
    uint32_t voiceChannel;         // channel offset inside that interleaved buffer
} EquIOLayout;

/// Sets the IO layout. Call while the IOProc is stopped.
void equ_engine_set_io_layout(EquEngine *engine, const EquIOLayout *layout);

/// AudioDeviceIOProc for the private aggregate device. Pass the EquEngine* as client data.
/// Reads the tap, processes, writes the device output (all other output channels are zeroed),
/// updates meters, feeds the recording ring and measures DSP load. Real-time safe.
OSStatus equ_engine_ioproc(AudioObjectID inDevice, const AudioTimeStamp *inNow,
                           const AudioBufferList *inInputData, const AudioTimeStamp *inInputTime,
                           AudioBufferList *outOutputData, const AudioTimeStamp *inOutputTime,
                           void *_Nullable inClientData);

// MARK: - Meters and statistics (any thread)

typedef struct EquMeters {
    float inputPeak[2];          // linear, max |x| since the previous read
    float inputRMS[2];           // linear, ~300 ms exponential RMS
    float outputPeak[2];         // linear, max |y| since the previous read (post-limiter, as sent to the device)
    float outputRMS[2];
    float gainReductionDB;       // limiter gain reduction, max since previous read (>= 0)
    float dspLoad;               // mean fraction of the IO period spent processing (last ~1 s)
    float dspLoadPeak;           // max fraction since previous read
    float voicePeak;             // linear peak of the raw voice input since the previous read (0 without voice)
    float outputRMSFast[2];      // ~40 ms RMS of the output (linear): follows the music's loudness even when peaks sit at the limiter ceiling
    double inputSilenceSeconds;  // how long the input has been exact digital zero (0 when signal present)
    double ioLatencyFrames;      // inOutputTime.mSampleTime - inInputTime.mSampleTime of the last IO cycle
    uint64_t framesProcessed;
    uint64_t ioCycles;
    uint64_t clippedSamples;     // samples clamped by the safety clipper (cumulative)
    uint64_t layoutErrors;       // IO cycles with an unexpected buffer layout (output silenced)
    uint64_t nonFiniteResets;    // NaN/Inf recoveries (state reset, block silenced)
} EquMeters;

/// Reads meters and statistics; resets the "since previous read" peak values.
void equ_engine_read_meters(EquEngine *engine, EquMeters *outMeters);

// MARK: - Analysis taps (visualisation)

#define EQU_ANALYSIS_CAPACITY 16384

/// Copies the most recent `count` (<= EQU_ANALYSIS_CAPACITY) samples of the analysis taps, oldest first:
/// the mono input (before any processing) and the final left/right output (after the limiter and bypass).
/// Lock-free: the audio thread keeps writing, so a copy can contain a few samples from a newer cycle, which is
/// irrelevant for display. Returns the number of samples copied.
uint32_t equ_engine_analysis_read(EquEngine *engine, float *inputMono, float *outputLeft, float *outputRight, uint32_t count);

// MARK: - Recording ring (single producer: audio thread; single consumer: recorder thread)

#define EQU_RECORDING_CHANNELS 4  // interleaved frame layout: rawL, rawR, processedL, processedR

/// Enables/disables pushing frames into the recording ring. The ring (>= 5 s at 192 kHz) is
/// allocated by equ_engine_create, so enabling is safe while the audio thread runs.
/// Enabling discards stale frames and resets the dropped-frame counter. Call set_enabled and
/// recording_read from the same consumer thread (or serialise them).
void equ_engine_recording_set_enabled(EquEngine *engine, bool enabled);
bool equ_engine_recording_enabled(const EquEngine *engine);

/// Copies up to maxFrames interleaved 4-channel frames into dst. Returns the number of frames read.
uint32_t equ_engine_recording_read(EquEngine *engine, float *dst, uint32_t maxFrames);

/// Frames lost because the consumer did not drain the ring in time (cumulative since enable).
uint64_t equ_engine_recording_dropped_frames(const EquEngine *engine);

#ifdef __cplusplus
}
#endif

CF_ASSUME_NONNULL_END

#endif /* EQUCORE_H */
