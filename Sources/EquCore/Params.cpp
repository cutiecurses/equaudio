// Parameter metadata and validation shared by the engine, presets and the UI.
// Identifiers are persisted in presets/settings: never rename or reuse them.

#include "EquCore.h"

#include <cmath>
#include <cstring>

namespace {

struct ParamSpec {
    const char *identifier;
    const char *displayName;
    const char *unit;
    float minValue;
    float maxValue;
    float defaultValue;
    float displayScale;
    bool isToggle;
};

constexpr ParamSpec kSpecs[EquParamCount] = {
    /* Bypass            */ {"bypass", "Bypass", "", 0, 1, 0, 1, true},
    /* PreampDB          */ {"preamp_db", "Preamp", "dB", -24, 12, 0, 1, false},
    /* AutoHeadroom      */ {"auto_headroom", "Auto Headroom", "", 0, 1, 1, 1, true},
    /* EQEnabled         */ {"eq_enabled", "Equalizer", "", 0, 1, 1, 1, true},
    /* EQBand0           */ {"eq_31", "31 Hz", "dB", -12, 12, 0, 1, false},
    /* EQBand1           */ {"eq_62", "62 Hz", "dB", -12, 12, 0, 1, false},
    /* EQBand2           */ {"eq_125", "125 Hz", "dB", -12, 12, 0, 1, false},
    /* EQBand3           */ {"eq_250", "250 Hz", "dB", -12, 12, 0, 1, false},
    /* EQBand4           */ {"eq_500", "500 Hz", "dB", -12, 12, 0, 1, false},
    /* EQBand5           */ {"eq_1k", "1 kHz", "dB", -12, 12, 0, 1, false},
    /* EQBand6           */ {"eq_2k", "2 kHz", "dB", -12, 12, 0, 1, false},
    /* EQBand7           */ {"eq_4k", "4 kHz", "dB", -12, 12, 0, 1, false},
    /* EQBand8           */ {"eq_8k", "8 kHz", "dB", -12, 12, 0, 1, false},
    /* EQBand9           */ {"eq_16k", "16 kHz", "dB", -12, 12, 0, 1, false},
    /* BassBoostDB       */ {"bass_boost_db", "Bass Boost", "dB", 0, 12, 0, 1, false},
    /* SubBassDB         */ {"sub_bass_db", "Sub-Bass", "dB", 0, 12, 0, 1, false},
    /* BassHarmonics     */ {"bass_harmonics", "Bass Harmonics", "%", 0, 1, 0, 100, false},
    /* TrebleDB          */ {"treble_db", "Treble", "dB", -9, 9, 0, 1, false},
    /* Clarity           */ {"clarity", "Clarity", "%", 0, 1, 0, 100, false},
    /* Loudness          */ {"loudness", "Loudness", "%", 0, 1, 0, 100, false},
    /* StereoWidth       */ {"stereo_width", "Stereo Width", "%", 0, 2, 1, 100, false},
    /* BassMono          */ {"bass_mono", "Bass Mono", "", 0, 1, 0, 1, true},
    /* CrossfeedEnabled  */ {"crossfeed", "Crossfeed", "", 0, 1, 0, 1, true},
    /* CrossfeedCutoffHz */ {"crossfeed_hz", "Crossfeed Cutoff", "Hz", 300, 2000, 700, 1, false},
    /* CrossfeedFeedDB   */ {"crossfeed_db", "Crossfeed Level", "dB", 1, 15, 4.5f, 1, false},
    /* OutputGainDB      */ {"output_db", "Output Gain", "dB", -24, 12, 0, 1, false},
    /* LimiterEnabled    */ {"limiter", "Limiter", "", 0, 1, 1, 1, true},
    /* LimiterCeilingDB  */ {"limiter_ceiling_db", "Limiter Ceiling", "dB", -12, 0, -1, 1, false},
    /* LimiterReleaseMS  */ {"limiter_release_ms", "Limiter Release", "ms", 10, 1000, 150, 1, false},
    /* LimiterTruePeak   */ {"limiter_true_peak", "True Peak", "", 0, 1, 1, 1, true},
    /* ReverbMix         */ {"reverb_mix", "Reverb", "%", 0, 1, 0, 100, false},
    /* ReverbSize        */ {"reverb_size", "Reverb Size", "%", 0, 1, 0.5f, 100, false},
    /* ReverbDamping     */ {"reverb_damping", "Reverb Damping", "%", 0, 1, 0.5f, 100, false},
    /* Spatial           */ {"spatial", "3D Spatial", "%", 0, 1, 0, 100, false},
    /* DeepBass          */ {"deep_bass", "Deep Bass", "%", 0, 1, 0, 100, false},
    /* VoiceGainDB       */ {"voice_gain_db", "Voice", "dB", -40, 12, 0, 1, false},
    /* VoiceMute         */ {"voice_mute", "Mute Mic", "", 0, 1, 0, 1, true},
    /* VoiceDuck         */ {"voice_duck", "Duck Music", "%", 0, 1, 0, 100, false},
};

static_assert(sizeof(kSpecs) / sizeof(kSpecs[0]) == EquParamCount, "parameter table out of sync with EquParam");

} // namespace

extern "C" bool equ_param_info(EquParam param, EquParamInfo *outInfo) {
    if (static_cast<uint32_t>(param) >= EquParamCount || outInfo == nullptr) return false;
    const ParamSpec &s = kSpecs[param];
    outInfo->identifier = s.identifier;
    outInfo->displayName = s.displayName;
    outInfo->unit = s.unit;
    outInfo->minValue = s.minValue;
    outInfo->maxValue = s.maxValue;
    outInfo->defaultValue = s.defaultValue;
    outInfo->displayScale = s.displayScale;
    outInfo->isToggle = s.isToggle;
    return true;
}

extern "C" float equ_param_validate(EquParam param, float value) {
    if (static_cast<uint32_t>(param) >= EquParamCount) return 0.0f;
    const ParamSpec &s = kSpecs[param];
    if (!std::isfinite(value)) return s.defaultValue;
    if (s.isToggle) return value >= 0.5f ? 1.0f : 0.0f;
    if (value < s.minValue) return s.minValue;
    if (value > s.maxValue) return s.maxValue;
    return value;
}

extern "C" bool equ_param_from_identifier(const char *identifier, EquParam *outParam) {
    if (identifier == nullptr) return false;
    for (uint32_t i = 0; i < EquParamCount; ++i) {
        if (std::strcmp(kSpecs[i].identifier, identifier) == 0) {
            if (outParam) *outParam = static_cast<EquParam>(i);
            return true;
        }
    }
    return false;
}

extern "C" double equ_eq_band_frequency(uint32_t band) {
    if (band >= EQU_EQ_BAND_COUNT) return 0.0;
    return 31.25 * std::ldexp(1.0, static_cast<int>(band));
}
