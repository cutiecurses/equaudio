// EquCore engine: 10-band EQ, bass/sub/clarity/treble/loudness, harmonics, width, crossfeed, look-ahead limiter, bypass, meters, recording ring, IOProc.

#include "EquCore.h"

#include <algorithm>
#include <atomic>
#include <cmath>
#include <complex>
#include <cstring>
#include <new>
#include <vector>


namespace {
constexpr uint32_t kRingFrames = 1u << 20; // ~5.4 s at 192 kHz
constexpr double kReverbScale = 3.0; // Freeverb wet scale; level checked by EngineTests.reverbLevelIsReasonable
constexpr uint32_t kAna = EQU_ANALYSIS_CAPACITY; // power of two
constexpr uint32_t kLook = 96;             // limiter look-ahead = engine latency (frames)
constexpr uint32_t kBands = EQU_EQ_BAND_COUNT;
inline float dbToGain(float db) { return std::pow(10.0f, db / 20.0f); }

enum class Kind { Bell, LowShelf, HighShelf, HighPass };

// RBJ cookbook biquad (transposed direct form II), coefficients in double.
struct Biquad {
    double b0 = 1, b1 = 0, b2 = 0, a1 = 0, a2 = 0, z1 = 0, z2 = 0;
    void design(Kind k, double fs, double f0, double q, double gainDB) {
        f0 = std::min(f0, 0.45 * fs);
        const double A = std::pow(10.0, gainDB / 40.0), w = 2 * M_PI * f0 / fs, c = std::cos(w), sn = std::sin(w);
        const double al = sn / (2 * q);
        double a0;
        if (k == Kind::HighPass) {
            a0 = 1 + al; b0 = (1 + c) / 2 / a0; b1 = -(1 + c) / a0; b2 = (1 + c) / 2 / a0; a1 = -2 * c / a0; a2 = (1 - al) / a0;
        } else if (k == Kind::Bell) {
            a0 = 1 + al / A; b0 = (1 + al * A) / a0; b1 = -2 * c / a0; b2 = (1 - al * A) / a0; a1 = -2 * c / a0; a2 = (1 - al / A) / a0;
        } else {
            const double t = 2 * std::sqrt(A) * al;
            if (k == Kind::LowShelf) {
                a0 = (A + 1) + (A - 1) * c + t;
                b0 = A * ((A + 1) - (A - 1) * c + t) / a0; b1 = 2 * A * ((A - 1) - (A + 1) * c) / a0; b2 = A * ((A + 1) - (A - 1) * c - t) / a0;
                a1 = -2 * ((A - 1) + (A + 1) * c) / a0; a2 = ((A + 1) + (A - 1) * c - t) / a0;
            } else {
                a0 = (A + 1) - (A - 1) * c + t;
                b0 = A * ((A + 1) + (A - 1) * c + t) / a0; b1 = -2 * A * ((A - 1) + (A + 1) * c) / a0; b2 = A * ((A + 1) + (A - 1) * c - t) / a0;
                a1 = 2 * ((A - 1) - (A + 1) * c) / a0; a2 = ((A + 1) - (A - 1) * c - t) / a0;
            }
        }
    }
    inline double tick(double x) { double y = b0 * x + z1; z1 = b1 * x - a1 * y + z2; z2 = b2 * x - a2 * y; return y; }
    double magnitudeDB(double fs, double f) const {
        const double w = 2 * M_PI * f / fs;
        std::complex<double> z1_(std::cos(-w), std::sin(-w)), z2_ = z1_ * z1_;
        return 20 * std::log10(std::abs((b0 + b1 * z1_ + b2 * z2_) / (1.0 + a1 * z1_ + a2 * z2_)) + 1e-30);
    }
};

// Freeverb-style stereo reverb (Schroeder/Moorer: 8 damped combs + 4 allpasses per channel), tunings scaled to the sample rate.
struct Comb { std::vector<float> buf; uint32_t idx = 0; float store = 0; };
struct Allpass { std::vector<float> buf; uint32_t idx = 0; };
constexpr uint32_t kCombLen[8] = {1116, 1188, 1277, 1356, 1422, 1491, 1557, 1617};
constexpr uint32_t kAllpassLen[4] = {556, 441, 341, 225};
constexpr uint32_t kStereoSpread = 23;

// One smoothed filter stage used for both channels.
struct Stage {
    Kind kind = Kind::Bell; double f0 = 1000, q = 1; double cur = 0, target = 0;
    Biquad bq[2];
    void setup(double fs) { for (auto &b : bq) b.design(kind, fs, f0, q, cur); }
    // Called every sub-block: glide the gain (~25 ms) and redesign while moving.
    void update(double fs, double coef) {
        if (std::fabs(target - cur) < 1e-4) { if (cur != target) { cur = target; for (auto &b : bq) { Biquad n; n.design(kind, fs, f0, q, cur); n.z1 = b.z1; n.z2 = b.z2; b = n; } } return; }
        cur += (target - cur) * coef;
        for (auto &b : bq) { double z1 = b.z1, z2 = b.z2; b.design(kind, fs, f0, q, cur); b.z1 = z1; b.z2 = z2; }
    }
};
} // namespace

struct EquEngine {
    std::atomic<float> params[EquParamCount];
    double sampleRate = 48000.0;
    uint32_t maxFrames = 4096;
    std::vector<float> scratchL, scratchR;
    EquIOLayout layout{0, 0, 0, 0, 1, false, 0, 0, 0, 0, false, 0, 0};
    std::atomic<bool> outputMuted{false};

    // DSP state (audio thread owns it; params are read atomically)
    Stage eq[kBands], bass, sub, clarity, presence, treble, subsonic;
    double smoothPre = 1, smoothOut = 1, smoothWidth = 1, smoothHarm = 0, smoothBypass = 0, smoothCF = 0, limGain = 1;
    double hp1[2] = {0, 0}, lpA = 0, lpB = 0, lpC = 0, cfLP[2] = {0, 0};
    std::vector<float> delayL, delayR, dryL, dryR; uint32_t dpos = 0;
    // reverb + spatial
    Comb combL[8], combR[8]; Allpass apL[4], apR[4];
    std::vector<float> predelay, erBuf; uint32_t pdPos = 0, pdLen = 1, erPos = 0, erMask = 0, erDL[3] = {0, 0, 0}, erDR[3] = {0, 0, 0};
    double deepEnv = 0, subLP1 = 0, subLP2 = 0, smoothDeep = 0, deepGate = 0; bool deepHigh = false, deepFlip = false, deepActive = false; uint32_t sinceRise = 0;
    // voice mix
    double voiceLP = 0, voiceEnv = 0, duckGain = 1, voiceSmooth = 0; std::atomic<float> voicePk{0};
    double rvHP = 0, spLP = 0, erLow = 0, erLP[2] = {0, 0}, smoothRv = 0, smoothSp = 0, smoothSize = 0.5, smoothDamp = 0.5;
    std::vector<float> reqGain; // per-sample required gain, circular
    std::atomic<float> headroom{0}, grMax{0};
    std::atomic<float> inPeak[2], outPeak[2];
    std::atomic<float> inRMS[2], outRMS[2], outRMSFast[2];
    double outMSFast[2] = {0, 0};
    double inMS[2] = {0, 0}, outMS[2] = {0, 0};
    std::atomic<uint64_t> frames{0}, cycles{0}, layoutErrors{0}, nonFinite{0}, clipped{0};
    std::atomic<double> silenceSeconds{0}, ioLatency{0};

    std::vector<float> anaIn, anaL, anaR;
    std::atomic<uint32_t> anaPos{0};
    std::vector<float> ring;
    std::atomic<uint64_t> ringWrite{0}, ringRead{0}, ringDropped{0};
    std::atomic<bool> recording{false};

    EquEngine() : ring(static_cast<size_t>(kRingFrames) * EQU_RECORDING_CHANNELS) {
        anaIn.assign(kAna, 0.0f); anaL.assign(kAna, 0.0f); anaR.assign(kAna, 0.0f);
        for (uint32_t i = 0; i < EquParamCount; ++i) {
            EquParamInfo info;
            equ_param_info(static_cast<EquParam>(i), &info);
            params[i].store(info.defaultValue);
        }
        for (int c = 0; c < 2; ++c) { inPeak[c] = outPeak[c] = inRMS[c] = outRMS[c] = outRMSFast[c] = 0.0f; }
    }
};

static void pushRecording(EquEngine *e, const float *rl, const float *rr, const float *pl, const float *pr, uint32_t n) {
    if (!e->recording.load(std::memory_order_acquire)) return;
    uint64_t w = e->ringWrite.load(std::memory_order_relaxed);
    uint64_t r = e->ringRead.load(std::memory_order_acquire);
    uint64_t space = kRingFrames - (w - r);
    uint32_t todo = n;
    if (todo > space) { e->ringDropped.fetch_add(todo - space, std::memory_order_relaxed); todo = static_cast<uint32_t>(space); }
    for (uint32_t i = 0; i < todo; ++i) {
        float *f = &e->ring[((w + i) & (kRingFrames - 1)) * EQU_RECORDING_CHANNELS];
        f[0] = rl[i]; f[1] = rr[i]; f[2] = pl[i]; f[3] = pr[i];
    }
    e->ringWrite.store(w + todo, std::memory_order_release);
}

static inline float P(const EquEngine *e, EquParam p) { return e->params[p].load(std::memory_order_relaxed); }

// Sets the gain targets of every filter from the current parameters (audio thread, once per sub-block).
static void updateTargets(EquEngine *e) {
    const bool eqOn = P(e, EquParamEQEnabled) > 0.5f;
    float maxBoost = 0;
    for (uint32_t b = 0; b < kBands; ++b) {
        float g = eqOn ? P(e, static_cast<EquParam>(EquParamEQBand0 + b)) : 0.0f;
        e->eq[b].target = g; maxBoost = std::max(maxBoost, g);
    }
    const float loud = P(e, EquParamLoudness), clar = P(e, EquParamClarity);
    const float bassG = P(e, EquParamBassBoostDB) + loud * 6.0f, trebG = P(e, EquParamTrebleDB) + loud * 1.6f;
    e->bass.target = bassG; e->sub.target = P(e, EquParamSubBassDB);
    e->presence.target = 5.0f * clar; e->clarity.target = -2.5f * clar; e->treble.target = trebG;
    maxBoost = std::max({maxBoost, bassG, (float)e->sub.target, (float)e->presence.target, trebG});
    (void)maxBoost;
}

// Control thread: headroom. Boosting a band must not make the whole signal quieter, so this offsets only the
// *average* boost over 40 Hz-16 kHz (pink-noise weighted, i.e. equal weight per octave), partially (75%, max 9 dB).
// Isolated peaks of the boosted region are caught by the look-ahead limiter.
static void computeHeadroom(EquEngine *e) {
    if (P(e, EquParamAutoHeadroom) < 0.5f) { e->headroom.store(0.0f); return; }
    float freqs[96], db[96];
    for (int i = 0; i < 96; ++i) freqs[i] = (float)(40.0 * std::pow(std::min(16000.0, 0.45 * e->sampleRate) / 40.0, i / 95.0));
    equ_engine_response_db(e, freqs, db, 96, EquResponseEQ | EquResponseTone);
    double energy = 0; for (float v : db) energy += std::pow(10.0, v / 10.0);
    double avgBoost = 10.0 * std::log10(energy / 96.0);
    e->headroom.store((float)-std::min(9.0, std::max(0.0, 0.75 * avgBoost)));
}

static void setupStages(EquEngine *e) {
    for (uint32_t b = 0; b < kBands; ++b) { e->eq[b].kind = Kind::Bell; e->eq[b].f0 = equ_eq_band_frequency(b); e->eq[b].q = 1.1; }
    e->bass = Stage{Kind::LowShelf, 100, 0.6}; e->sub = Stage{Kind::Bell, 45, 1.0};
    e->presence = Stage{Kind::Bell, 3000, 0.8}; e->clarity = Stage{Kind::Bell, 300, 1.0}; e->treble = Stage{Kind::HighShelf, 8000, 0.6};
    // Subsonic protection: nothing useful below ~22 Hz, and boosted sub-bass there only eats headroom and drives small drivers.
    e->subsonic = Stage{Kind::HighPass, 22, 0.7071};
    e->subsonic.cur = e->subsonic.target = 0; e->subsonic.setup(e->sampleRate);
    for (auto &s : e->eq) { s.cur = s.target = 0; s.setup(e->sampleRate); }
    for (Stage *s : {&e->bass, &e->sub, &e->presence, &e->clarity, &e->treble}) { s->cur = s->target = 0; s->setup(e->sampleRate); }
}

static inline double onePole(double fc, double fs) { return 1.0 - std::exp(-2 * M_PI * fc / fs); }

static void processBlock(EquEngine *e, const float *inL, const float *inR, float *outL, float *outR, uint32_t n, const float *voice = nullptr) {
    const double fs = e->sampleRate;
    const double fastCoef = std::exp(-1.0 / (0.04 * fs));
    const double rmsCoef = std::exp(-1.0 / (0.3 * fs)), smooth = 1.0 - std::exp(-1.0 / (0.02 * fs));
    float ip[2] = {0, 0}, op[2] = {0, 0}, gr = 0;
    float *rawL = e->scratchL.data(), *rawR = e->scratchR.data();
    std::memcpy(rawL, inL, n * sizeof(float));
    std::memcpy(rawR, inR, n * sizeof(float));
    const double ceil = dbToGain(P(e, EquParamLimiterCeilingDB));
    uint32_t apos = e->anaPos.load(std::memory_order_relaxed);
    const bool limOn = P(e, EquParamLimiterEnabled) > 0.5f, byp = P(e, EquParamBypass) > 0.5f;
    const double relCoef = std::exp(-1.0 / (std::max(10.0f, P(e, EquParamLimiterReleaseMS)) * 0.001 * fs));
    const double hpCoef = onePole(30, fs), lp1 = onePole(120, fs), lp2 = onePole(400, fs), cfCoef = onePole(P(e, EquParamCrossfeedCutoffHz), fs);
    const double cfK = std::pow(10.0, -P(e, EquParamCrossfeedFeedDB) / 20.0);
    const double harmT = P(e, EquParamBassHarmonics), widthT = P(e, EquParamStereoWidth);
    const double rvT = P(e, EquParamReverbMix), spT = P(e, EquParamSpatial), sizeT = P(e, EquParamReverbSize), dampT = P(e, EquParamReverbDamping);
    const double voiceHpCoef = onePole(80, fs), envAtt = onePole(60, fs), envRel = onePole(3, fs);
    const double duckAmt = P(e, EquParamVoiceDuck), duckAtt = onePole(25, fs), duckRel = onePole(1.5, fs);
    const double voiceTarget = P(e, EquParamVoiceMute) > 0.5f ? 0.0 : std::pow(10.0, P(e, EquParamVoiceGainDB) / 20.0);
    float vpeak = 0;
    const double spCoef = onePole(250, fs), erLpCoef = onePole(6000, fs), rvHpCoef = onePole(200, fs);
    const double deepT = P(e, EquParamDeepBass), deepAtt = onePole(60, fs), deepRel = onePole(8, fs), subCoef = onePole(55, fs);
    static const double erGain[3] = {0.55, 0.38, 0.27};
    const bool cfOn = P(e, EquParamCrossfeedEnabled) > 0.5f, bassMono = P(e, EquParamBassMono) > 0.5f;
    for (uint32_t i = 0; i < n; ++i) {
        if ((i & 31) == 0) {
            updateTargets(e);
            const double c = 1.0 - std::exp(-32.0 / (0.025 * fs));
            for (auto &s : e->eq) s.update(fs, c);
            for (Stage *s : {&e->bass, &e->sub, &e->presence, &e->clarity, &e->treble}) s->update(fs, c);
        }
        float l = std::isfinite(rawL[i]) ? rawL[i] : 0.0f, r = std::isfinite(rawR[i]) ? rawR[i] : 0.0f;
        ip[0] = std::fmax(ip[0], std::fabs(l)); ip[1] = std::fmax(ip[1], std::fabs(r));
        e->inMS[0] = rmsCoef * e->inMS[0] + (1 - rmsCoef) * l * l; e->inMS[1] = rmsCoef * e->inMS[1] + (1 - rmsCoef) * r * r;
        // gain staging
        e->smoothPre += (std::pow(10.0, (P(e, EquParamPreampDB) + e->headroom.load(std::memory_order_relaxed)) / 20.0) - e->smoothPre) * smooth;
        double xs[2] = {l * e->smoothPre, r * e->smoothPre};
        for (int c = 0; c < 2; ++c) {
            double x = e->subsonic.bq[c].tick(xs[c]);
            for (auto &s : e->eq) x = s.bq[c].tick(x);
            x = e->bass.bq[c].tick(x); x = e->sub.bq[c].tick(x); x = e->presence.bq[c].tick(x); x = e->clarity.bq[c].tick(x); x = e->treble.bq[c].tick(x);
            xs[c] = x;
        }
        // psychoacoustic bass: rectified 30-120 Hz band -> harmonics 120-400 Hz
        e->smoothHarm += (harmT - e->smoothHarm) * smooth;
        double m = 0.5 * (xs[0] + xs[1]);
        e->hp1[0] += hpCoef * (m - e->hp1[0]); double hb = m - e->hp1[0];
        e->lpA += lp1 * (hb - e->lpA);
        double rect = std::fabs(e->lpA); e->hp1[1] += onePole(60, fs) * (rect - e->hp1[1]);
        e->lpB += lp2 * ((rect - e->hp1[1]) - e->lpB);
        double harm = 2.5 * e->smoothHarm * e->lpB; xs[0] += harm; xs[1] += harm;
        // deep bass: octave-down subharmonic. A Schmitt trigger on the 30-120 Hz band flips a square wave on every
        // rising crossing (-> half the frequency), scaled by the band's envelope and low-passed to a smooth sine.
        // Only active for fundamentals of 38-130 Hz so it never creates inaudible rumble below ~19 Hz.
        e->smoothDeep += (deepT - e->smoothDeep) * smooth;
        if (e->smoothDeep > 1e-4) {
            const double b = e->lpA, a = std::fabs(b);
            e->deepEnv += (a > e->deepEnv ? deepAtt : deepRel) * (a - e->deepEnv);
            if (e->sinceRise < 1000000) e->sinceRise++;
            const double th = 0.15 * e->deepEnv + 1e-6;
            if (!e->deepHigh && b > th) {
                e->deepHigh = true; e->deepFlip = !e->deepFlip;
                const double freq = fs / std::max<uint32_t>(e->sinceRise, 1);
                e->deepActive = freq > 38.0 && freq < 130.0; e->sinceRise = 0;
            } else if (e->deepHigh && b < -th) e->deepHigh = false;
            if (e->sinceRise > fs / 25.0) e->deepActive = false;
            e->deepGate += ((e->deepActive ? 1.0 : 0.0) - e->deepGate) * smooth * 2;
            const double sq = (e->deepFlip ? 1.0 : -1.0) * e->deepEnv * e->deepGate;
            e->subLP1 += subCoef * (sq - e->subLP1); e->subLP2 += subCoef * (e->subLP1 - e->subLP2);
            const double sub = 2.6 * e->smoothDeep * e->subLP2;
            xs[0] += sub; xs[1] += sub;
        }
        // stereo width (mid unchanged), optional bass mono
        e->smoothWidth += (widthT - e->smoothWidth) * smooth;
        double M = 0.5 * (xs[0] + xs[1]), S = 0.5 * (xs[0] - xs[1]);
        e->lpC += lp1 * (S - e->lpC);
        double Sn = bassMono ? (S - e->lpC) * e->smoothWidth : S * e->smoothWidth;
        xs[0] = M + Sn; xs[1] = M - Sn;
        // crossfeed
        e->smoothCF += ((cfOn ? 1.0 : 0.0) - e->smoothCF) * smooth;
        if (e->smoothCF > 1e-4) {
            e->cfLP[0] += cfCoef * (xs[0] - e->cfLP[0]); e->cfLP[1] += cfCoef * (xs[1] - e->cfLP[1]);
            double k = cfK * e->smoothCF, norm = 1.0 / (1.0 + k);
            double nl = (xs[0] + k * e->cfLP[1]) * norm, nr = (xs[1] + k * e->cfLP[0]) * norm; xs[0] = nl; xs[1] = nr;
        }
        // spatial: side-channel highs lifted (mono-safe: mid untouched) + stereo early reflections from the mid
        e->smoothSp += (spT - e->smoothSp) * smooth;
        if (e->smoothSp > 1e-4) {
            double Mm = 0.5 * (xs[0] + xs[1]), Ss = 0.5 * (xs[0] - xs[1]);
            e->spLP += spCoef * (Ss - e->spLP);
            Ss += e->smoothSp * 1.0 * (Ss - e->spLP);
            e->erLow += spCoef * (Mm - e->erLow);           // reflections only above ~250 Hz: the low end stays clean
            e->erBuf[e->erPos & e->erMask] = (float)(Mm - e->erLow);
            double erL = 0, erR = 0;
            for (int t = 0; t < 3; ++t) { erL += erGain[t] * e->erBuf[(e->erPos - e->erDL[t]) & e->erMask]; erR += erGain[t] * e->erBuf[(e->erPos - e->erDR[t]) & e->erMask]; }
            e->erLP[0] += erLpCoef * (erL - e->erLP[0]); e->erLP[1] += erLpCoef * (erR - e->erLP[1]);
            e->erPos++;
            xs[0] = Mm + Ss + 0.45 * e->smoothSp * e->erLP[0]; xs[1] = Mm - Ss + 0.45 * e->smoothSp * e->erLP[1];
        }
        // reverb: bass below ~200 Hz is kept out of the tail so low end stays tight
        e->smoothRv += (rvT - e->smoothRv) * smooth;
        e->smoothSize += (sizeT - e->smoothSize) * smooth * 0.1; e->smoothDamp += (dampT - e->smoothDamp) * smooth * 0.1;
        if (e->smoothRv > 1e-4) {
            const float fb = (float)(0.70 + 0.28 * e->smoothSize), damp = (float)(0.10 + 0.70 * e->smoothDamp);
            double in = xs[0] + xs[1];
            e->rvHP += rvHpCoef * (in - e->rvHP);
            e->predelay[e->pdPos] = (float)(in - e->rvHP); float pd = e->predelay[(e->pdPos + 1) % e->pdLen]; e->pdPos = (e->pdPos + 1) % e->pdLen;
            const float inp = pd * 0.015f;
            float oL = 0, oR = 0;
            for (int i = 0; i < 8; ++i) {
                Comb &cl = e->combL[i], &cr = e->combR[i];
                float yl = cl.buf[cl.idx]; cl.store = yl * (1 - damp) + cl.store * damp; cl.buf[cl.idx] = inp + cl.store * fb; if (++cl.idx >= cl.buf.size()) cl.idx = 0; oL += yl;
                float yr = cr.buf[cr.idx]; cr.store = yr * (1 - damp) + cr.store * damp; cr.buf[cr.idx] = inp + cr.store * fb; if (++cr.idx >= cr.buf.size()) cr.idx = 0; oR += yr;
            }
            for (int i = 0; i < 4; ++i) {
                Allpass &al = e->apL[i], &ar = e->apR[i];
                float bl = al.buf[al.idx]; float nl = -oL + bl; al.buf[al.idx] = oL + bl * 0.5f; if (++al.idx >= al.buf.size()) al.idx = 0; oL = nl;
                float br = ar.buf[ar.idx]; float nr = -oR + br; ar.buf[ar.idx] = oR + br * 0.5f; if (++ar.idx >= ar.buf.size()) ar.idx = 0; oR = nr;
            }
            const double g = e->smoothRv * kReverbScale;
            xs[0] += oL * g; xs[1] += oR * g;
        }
        e->smoothOut += (std::pow(10.0, P(e, EquParamOutputGainDB) / 20.0) - e->smoothOut) * smooth;
        float wl = (float)(xs[0] * e->smoothOut), wr = (float)(xs[1] * e->smoothOut);
        // voice: 80 Hz high-passed, gain/mute smoothed; the music ducks while the voice envelope is above ~-40 dBFS
        double vs = 0;
        if (voice) {
            const double vin = std::isfinite(voice[i]) ? voice[i] : 0.0;
            vpeak = std::fmax(vpeak, (float)std::fabs(vin));
            e->voiceLP += voiceHpCoef * (vin - e->voiceLP);
            vs = vin - e->voiceLP;
            const double a = std::fabs(vs);
            e->voiceEnv += (a > e->voiceEnv ? envAtt : envRel) * (a - e->voiceEnv);
        } else {
            e->voiceEnv += envRel * (0.0 - e->voiceEnv);
        }
        e->voiceSmooth += (voiceTarget - e->voiceSmooth) * smooth;
        const double duckTarget = (duckAmt > 0 && e->voiceEnv > 0.01) ? 1.0 - 0.75 * duckAmt : 1.0;
        e->duckGain += (duckTarget - e->duckGain) * (duckTarget < e->duckGain ? duckAtt : duckRel);
        wl = (float)(wl * e->duckGain + vs * e->voiceSmooth); wr = (float)(wr * e->duckGain + vs * e->voiceSmooth);
        // look-ahead limiter: input is delayed kLook frames; gain = smoothed min of required gain over the window
        uint32_t w = e->dpos;
        e->delayL[w] = wl; e->delayR[w] = wr;
        float peak = std::fmax(std::fabs(wl), std::fabs(wr));
        e->reqGain[w] = (limOn && peak > ceil) ? (float)(ceil / peak) : 1.0f;
        float target = 1.0f;
        for (uint32_t k = 0; k < kLook; ++k) target = std::fmin(target, e->reqGain[(w + kLook - k) % kLook]);
        if (target < e->limGain) e->limGain += (target - e->limGain) * 0.35; else e->limGain = target + (e->limGain - target) * relCoef;
        if (e->limGain > target && target < 1.0f) e->limGain = std::fmin(e->limGain, 1.0);
        uint32_t rd = (w + 1) % kLook; // oldest sample = delayed by kLook-1 frames
        float yl = e->delayL[rd] * (float)e->limGain, yr = e->delayR[rd] * (float)e->limGain;
        if (limOn) { double lim = std::min(1.0, ceil); yl = (float)std::fmax(-lim, std::fmin(lim, yl)); yr = (float)std::fmax(-lim, std::fmin(lim, yr)); }
        gr = std::fmax(gr, (float)(-20 * std::log10(std::max(e->limGain, 1e-6))));
        // dry path delayed by the same amount for a time-aligned A/B
        e->dryL[w] = l; e->dryR[w] = r;
        float dl = e->dryL[rd], dr = e->dryR[rd];
        e->dpos = (w + 1) % kLook;
        e->smoothBypass += ((byp ? 1.0 : 0.0) - e->smoothBypass) * smooth * 0.5;
        float b = (float)e->smoothBypass;
        yl = yl * (1 - b) + dl * b; yr = yr * (1 - b) + dr * b;
        if (!std::isfinite(yl) || !std::isfinite(yr)) { equ_engine_reset(e); yl = yr = 0; e->nonFinite.fetch_add(1); }
        if (std::fabs(yl) > 1.0f) { yl = yl > 0 ? 1.0f : -1.0f; e->clipped.fetch_add(1); }
        if (std::fabs(yr) > 1.0f) { yr = yr > 0 ? 1.0f : -1.0f; e->clipped.fetch_add(1); }
        outL[i] = yl; outR[i] = yr;
        { const uint32_t slot = (apos + i) & (kAna - 1); e->anaIn[slot] = 0.5f * (l + r); e->anaL[slot] = yl; e->anaR[slot] = yr; }
        op[0] = std::fmax(op[0], std::fabs(yl)); op[1] = std::fmax(op[1], std::fabs(yr));
        e->outMS[0] = rmsCoef * e->outMS[0] + (1 - rmsCoef) * yl * yl; e->outMS[1] = rmsCoef * e->outMS[1] + (1 - rmsCoef) * yr * yr;
        e->outMSFast[0] = fastCoef * e->outMSFast[0] + (1 - fastCoef) * yl * yl; e->outMSFast[1] = fastCoef * e->outMSFast[1] + (1 - fastCoef) * yr * yr;
        // keep dry-delayed raw for recording alongside processed
        rawL[i] = dl; rawR[i] = dr;
    }
    for (int c = 0; c < 2; ++c) {
        if (ip[c] > e->inPeak[c].load()) e->inPeak[c].store(ip[c]);
        if (op[c] > e->outPeak[c].load()) e->outPeak[c].store(op[c]);
        e->inRMS[c].store(static_cast<float>(std::sqrt(e->inMS[c]))); e->outRMS[c].store(static_cast<float>(std::sqrt(e->outMS[c]))); e->outRMSFast[c].store(static_cast<float>(std::sqrt(e->outMSFast[c])));
    }
    e->anaPos.store(apos + n, std::memory_order_release);
    if (gr > e->grMax.load()) e->grMax.store(gr);
    if (vpeak > e->voicePk.load()) e->voicePk.store(vpeak);
    bool silent = ip[0] == 0.0f && ip[1] == 0.0f;
    e->silenceSeconds.store(silent ? e->silenceSeconds.load() + n / e->sampleRate : 0.0);
    e->frames.fetch_add(n);
    pushRecording(e, rawL, rawR, outL, outR, n);
}

extern "C" {

EquEngine *equ_engine_create(void) {
    EquEngine *e = new (std::nothrow) EquEngine();
    if (e) equ_engine_prepare(e, 48000.0, 4096);
    return e;
}

void equ_engine_destroy(EquEngine *engine) { delete engine; }

bool equ_engine_prepare(EquEngine *e, double sampleRate, uint32_t maxFrames) {
    if (!e || !(sampleRate >= 8000.0 && sampleRate <= 384000.0) || maxFrames == 0) return false;
    e->sampleRate = sampleRate;
    e->maxFrames = maxFrames;
    e->scratchL.assign(maxFrames, 0.0f);
    e->scratchR.assign(maxFrames, 0.0f);
    e->delayL.assign(kLook, 0.0f); e->delayR.assign(kLook, 0.0f); e->dryL.assign(kLook, 0.0f); e->dryR.assign(kLook, 0.0f); e->reqGain.assign(kLook, 1.0f);
    setupStages(e);
    const double k = sampleRate / 44100.0;
    for (int i = 0; i < 8; ++i) {
        e->combL[i].buf.assign((size_t)std::lround(kCombLen[i] * k) + 1, 0.0f);
        e->combR[i].buf.assign((size_t)std::lround((kCombLen[i] + kStereoSpread) * k) + 1, 0.0f);
    }
    for (int i = 0; i < 4; ++i) {
        e->apL[i].buf.assign((size_t)std::lround(kAllpassLen[i] * k) + 1, 0.0f);
        e->apR[i].buf.assign((size_t)std::lround((kAllpassLen[i] + kStereoSpread) * k) + 1, 0.0f);
    }
    e->pdLen = std::max<uint32_t>(1, (uint32_t)std::lround(0.020 * sampleRate)); e->predelay.assign(e->pdLen, 0.0f);
    uint32_t erN = 1; while (erN < (uint32_t)(0.04 * sampleRate)) erN <<= 1;
    e->erBuf.assign(erN, 0.0f); e->erMask = erN - 1;
    const double erMsL[3] = {7.0, 13.0, 19.0}, erMsR[3] = {9.5, 15.5, 23.0};
    for (int i = 0; i < 3; ++i) { e->erDL[i] = (uint32_t)std::lround(erMsL[i] * 0.001 * sampleRate); e->erDR[i] = (uint32_t)std::lround(erMsR[i] * 0.001 * sampleRate); }
    equ_engine_reset(e);
    computeHeadroom(e);
    return true;
}

void equ_engine_reset(EquEngine *e) {
    if (!e->delayL.empty()) { std::fill(e->delayL.begin(), e->delayL.end(), 0.0f); std::fill(e->delayR.begin(), e->delayR.end(), 0.0f); std::fill(e->dryL.begin(), e->dryL.end(), 0.0f); std::fill(e->dryR.begin(), e->dryR.end(), 0.0f); std::fill(e->reqGain.begin(), e->reqGain.end(), 1.0f); }
    for (auto &c : e->combL) { std::fill(c.buf.begin(), c.buf.end(), 0.0f); c.idx = 0; c.store = 0; }
    for (auto &c : e->combR) { std::fill(c.buf.begin(), c.buf.end(), 0.0f); c.idx = 0; c.store = 0; }
    for (auto &a : e->apL) { std::fill(a.buf.begin(), a.buf.end(), 0.0f); a.idx = 0; }
    for (auto &a : e->apR) { std::fill(a.buf.begin(), a.buf.end(), 0.0f); a.idx = 0; }
    std::fill(e->predelay.begin(), e->predelay.end(), 0.0f); std::fill(e->erBuf.begin(), e->erBuf.end(), 0.0f);
    e->voiceLP = e->voiceEnv = e->voiceSmooth = 0; e->duckGain = 1;
    e->deepEnv = e->subLP1 = e->subLP2 = e->deepGate = 0; e->deepHigh = e->deepFlip = e->deepActive = false; e->sinceRise = 0;
    e->pdPos = e->erPos = 0; e->rvHP = e->spLP = e->erLow = 0; e->erLP[0] = e->erLP[1] = 0;
    e->limGain = 1; e->dpos = 0; e->lpA = e->lpB = e->lpC = 0; e->hp1[0] = e->hp1[1] = 0; e->cfLP[0] = e->cfLP[1] = 0;
    for (auto &s : e->eq) for (auto &b : s.bq) b.z1 = b.z2 = 0;
    for (Stage *s : {&e->bass, &e->sub, &e->presence, &e->clarity, &e->treble, &e->subsonic}) for (auto &b : s->bq) b.z1 = b.z2 = 0;
    for (int c = 0; c < 2; ++c) { e->outMSFast[c] = 0; e->inMS[c] = e->outMS[c] = 0; e->inPeak[c] = e->outPeak[c] = e->inRMS[c] = e->outRMS[c] = 0.0f; }
}

double equ_engine_sample_rate(const EquEngine *e) { return e->sampleRate; }
uint32_t equ_engine_latency_frames(const EquEngine *) { return kLook - 1; }

void equ_engine_set_param(EquEngine *e, EquParam p, float v) {
    if (static_cast<uint32_t>(p) < EquParamCount) {
        e->params[p].store(equ_param_validate(p, v));
        if (p >= EquParamAutoHeadroom && p <= EquParamClarity) computeHeadroom(e);
        if (p == EquParamLoudness) computeHeadroom(e);
    }
}

float equ_engine_get_param(const EquEngine *e, EquParam p) {
    return static_cast<uint32_t>(p) < EquParamCount ? e->params[p].load() : 0.0f;
}

void equ_engine_set_host_volume_db(EquEngine *, float, bool) {}
void equ_engine_set_output_muted(EquEngine *e, bool muted) { e->outputMuted.store(muted); }
float equ_engine_auto_headroom_db(const EquEngine *e) { return e->headroom.load(); }

void equ_engine_response_db(const EquEngine *e, const float *freqs, float *outDB, uint32_t count, uint32_t stages) {
    const double fs = e->sampleRate;
    const bool eqOn = P(e, EquParamEQEnabled) > 0.5f;
    const float loud = P(e, EquParamLoudness), clar = P(e, EquParamClarity);
    Biquad bq; float maxBoost = 0;
    for (uint32_t b = 0; b < kBands; ++b) maxBoost = std::max(maxBoost, eqOn ? P(e, static_cast<EquParam>(EquParamEQBand0 + b)) : 0.0f);
    const float bassG = P(e, EquParamBassBoostDB) + loud * 6.0f, trebG = P(e, EquParamTrebleDB) + loud * 1.6f;
    maxBoost = std::max({maxBoost, bassG, P(e, EquParamSubBassDB), 5.0f * clar, trebG});
    for (uint32_t i = 0; i < count; ++i) {
        const double f = freqs[i]; double db = 0;
        if (stages & EquResponseGain) db += P(e, EquParamPreampDB) + P(e, EquParamOutputGainDB) + e->headroom.load();
        if ((stages & EquResponseEQ) && eqOn) for (uint32_t b = 0; b < kBands; ++b) { bq.design(Kind::Bell, fs, equ_eq_band_frequency(b), 1.1, P(e, static_cast<EquParam>(EquParamEQBand0 + b))); db += bq.magnitudeDB(fs, f); }
        if (stages & EquResponseTone) {
            bq.design(Kind::LowShelf, fs, 100, 0.6, bassG); db += bq.magnitudeDB(fs, f);
            bq.design(Kind::Bell, fs, 45, 1.0, P(e, EquParamSubBassDB)); db += bq.magnitudeDB(fs, f);
            bq.design(Kind::Bell, fs, 3000, 0.8, 5.0f * clar); db += bq.magnitudeDB(fs, f);
            bq.design(Kind::Bell, fs, 300, 1.0, -2.5f * clar); db += bq.magnitudeDB(fs, f);
            bq.design(Kind::HighShelf, fs, 8000, 0.6, trebG); db += bq.magnitudeDB(fs, f);
        }
        outDB[i] = (float)db;
    }
}

void equ_engine_eq_filter_gains(const EquEngine *e, float out[EQU_EQ_BAND_COUNT]) {
    for (uint32_t b = 0; b < EQU_EQ_BAND_COUNT; ++b) out[b] = e->params[EquParamEQBand0 + b].load();
}

void equ_engine_process(EquEngine *e, const float *inL, const float *inR, float *outL, float *outR, uint32_t frames) {
    while (frames > 0) {
        uint32_t n = frames < e->maxFrames ? frames : e->maxFrames;
        processBlock(e, inL, inR, outL, outR, n);
        inL += n; inR += n; outL += n; outR += n; frames -= n;
    }
}

void equ_engine_process_voice(EquEngine *e, const float *inL, const float *inR, const float *voice, float *outL, float *outR, uint32_t frames) {
    while (frames > 0) {
        uint32_t n = frames < e->maxFrames ? frames : e->maxFrames;
        processBlock(e, inL, inR, outL, outR, n, voice);
        inL += n; inR += n; outL += n; outR += n; frames -= n; if (voice) voice += n;
    }
}

void equ_engine_set_io_layout(EquEngine *e, const EquIOLayout *layout) { e->layout = *layout; }

OSStatus equ_engine_ioproc(AudioObjectID, const AudioTimeStamp *, const AudioBufferList *in, const AudioTimeStamp *inTime,
                           AudioBufferList *out, const AudioTimeStamp *outTime, void *client) {
    EquEngine *e = static_cast<EquEngine *>(client);
    if (!e || !out) return noErr;
    for (UInt32 b = 0; b < out->mNumberBuffers; ++b)
        if (out->mBuffers[b].mData) std::memset(out->mBuffers[b].mData, 0, out->mBuffers[b].mDataByteSize);
    const EquIOLayout &L = e->layout;
    if (!in || L.inputBuffer >= in->mNumberBuffers || L.outputLeftBuffer >= out->mNumberBuffers || L.outputRightBuffer >= out->mNumberBuffers) {
        e->layoutErrors.fetch_add(1);
        return noErr;
    }
    const AudioBuffer &ib = in->mBuffers[L.inputBuffer];
    const uint32_t ich = ib.mNumberChannels ? ib.mNumberChannels : 1;
    uint32_t frames = ib.mDataByteSize / (sizeof(float) * ich);
    if (frames > e->maxFrames) frames = e->maxFrames;
    const float *src = static_cast<const float *>(ib.mData);
    float l[4096], r[4096];
    if (frames > 4096) frames = 4096;
    for (uint32_t i = 0; i < frames; ++i) { l[i] = src ? src[i * ich] : 0.0f; r[i] = src ? src[i * ich + (ich > 1 ? 1 : 0)] : 0.0f; }
    float v[4096];
    const float *voicePtr = nullptr;
    if (L.voiceEnabled && L.voiceBuffer < in->mNumberBuffers) {
        const AudioBuffer &vb = in->mBuffers[L.voiceBuffer];
        const uint32_t vch = vb.mNumberChannels ? vb.mNumberChannels : 1, vframes = vb.mDataByteSize / (sizeof(float) * vch);
        const uint32_t vc = L.voiceChannel < vch ? L.voiceChannel : 0;
        const float *vsrc = static_cast<const float *>(vb.mData);
        for (uint32_t i = 0; i < frames; ++i) v[i] = (vsrc && i < vframes) ? vsrc[i * vch + vc] : 0.0f;
        voicePtr = v;
    }
    processBlock(e, l, r, l, r, frames, voicePtr);
    AudioBuffer &ob = out->mBuffers[L.outputLeftBuffer];
    AudioBuffer &obR = out->mBuffers[L.outputRightBuffer];
    const uint32_t ochL = ob.mNumberChannels ? ob.mNumberChannels : 1, ochR = obR.mNumberChannels ? obR.mNumberChannels : 1;
    float *dl = static_cast<float *>(ob.mData), *dr = static_cast<float *>(obR.mData);
    if (!e->outputMuted.load() && dl && dr) {
        for (uint32_t i = 0; i < frames; ++i) { dl[i * ochL + L.outputLeftChannel] = l[i]; dr[i * ochR + L.outputRightChannel] = r[i]; }
    }
    if (L.mirrorEnabled && L.mirrorLeftBuffer < out->mNumberBuffers && L.mirrorRightBuffer < out->mNumberBuffers) {
        AudioBuffer &mb = out->mBuffers[L.mirrorLeftBuffer];
        AudioBuffer &mbR = out->mBuffers[L.mirrorRightBuffer];
        const uint32_t mchL = mb.mNumberChannels ? mb.mNumberChannels : 1, mchR = mbR.mNumberChannels ? mbR.mNumberChannels : 1;
        float *ml = static_cast<float *>(mb.mData), *mr = static_cast<float *>(mbR.mData);
        if (ml && mr) {
            for (uint32_t i = 0; i < frames; ++i) { ml[i * mchL + L.mirrorLeftChannel] = l[i]; mr[i * mchR + L.mirrorRightChannel] = r[i]; }
        }
    }
    if (inTime && outTime) e->ioLatency.store(outTime->mSampleTime - inTime->mSampleTime);
    e->cycles.fetch_add(1);
    return noErr;
}

uint32_t equ_engine_analysis_read(EquEngine *e, float *inMono, float *outL, float *outR, uint32_t count) {
    if (count > kAna) count = kAna;
    const uint32_t end = e->anaPos.load(std::memory_order_acquire), start = end - count;
    for (uint32_t i = 0; i < count; ++i) {
        const uint32_t slot = (start + i) & (kAna - 1);
        inMono[i] = e->anaIn[slot]; outL[i] = e->anaL[slot]; outR[i] = e->anaR[slot];
    }
    return count;
}

void equ_engine_read_meters(EquEngine *e, EquMeters *m) {
    std::memset(m, 0, sizeof(*m));
    for (int c = 0; c < 2; ++c) {
        m->inputPeak[c] = e->inPeak[c].exchange(0.0f);
        m->outputPeak[c] = e->outPeak[c].exchange(0.0f);
        m->inputRMS[c] = e->inRMS[c].load();
        m->outputRMS[c] = e->outRMS[c].load();
        m->outputRMSFast[c] = e->outRMSFast[c].load();
    }
    m->inputSilenceSeconds = e->silenceSeconds.load();
    m->ioLatencyFrames = e->ioLatency.load();
    m->framesProcessed = e->frames.load();
    m->ioCycles = e->cycles.load();
    m->layoutErrors = e->layoutErrors.load();
    m->gainReductionDB = e->grMax.exchange(0.0f);
    m->voicePeak = e->voicePk.exchange(0.0f);
    m->clippedSamples = e->clipped.load(); m->nonFiniteResets = e->nonFinite.load();
}

void equ_engine_recording_set_enabled(EquEngine *e, bool enabled) {
    if (enabled) {
        e->ringRead.store(e->ringWrite.load(std::memory_order_acquire), std::memory_order_release);
        e->ringDropped.store(0);
    }
    e->recording.store(enabled, std::memory_order_release);
}

bool equ_engine_recording_enabled(const EquEngine *e) { return e->recording.load(); }

uint32_t equ_engine_recording_read(EquEngine *e, float *dst, uint32_t maxFrames) {
    uint64_t r = e->ringRead.load(std::memory_order_relaxed);
    uint64_t w = e->ringWrite.load(std::memory_order_acquire);
    uint32_t n = static_cast<uint32_t>(std::min<uint64_t>(w - r, maxFrames));
    for (uint32_t i = 0; i < n; ++i)
        std::memcpy(dst + i * EQU_RECORDING_CHANNELS, &e->ring[((r + i) & (kRingFrames - 1)) * EQU_RECORDING_CHANNELS], sizeof(float) * EQU_RECORDING_CHANNELS);
    e->ringRead.store(r + n, std::memory_order_release);
    return n;
}

uint64_t equ_engine_recording_dropped_frames(const EquEngine *e) { return e->ringDropped.load(); }

} // extern "C"
