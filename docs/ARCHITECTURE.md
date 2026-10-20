# EquAudio architecture

## Goal and the hard constraint

EquAudio processes the audio of *other* applications (Safari, Spotify, Music, games, video players)
in real time and plays the processed result on a physical output device, and can record exactly
that processed signal.

A normal macOS application cannot intercept another process's audio by itself. Something has to
route the audio to us. There are two supported routes:

| Option | How it works | Cost |
|---|---|---|
| **Core Audio process taps** (macOS 14.2+) | `AudioHardwareCreateProcessTap` creates a tap on other processes' output. A tap can *mute* the tapped processes on the hardware while we read their audio. | Needs the user's one-time "System Audio Recording" approval. No driver, no admin rights, nothing installed system-wide. |
| Virtual audio driver (BlackHole, Boom's `BoomAudio`, eqMac) | The user (or the app) switches the default output to a virtual device; the app reads it and plays to the real device. | Requires installing an AudioServerPlugIn into `/Library/Audio/Plug-Ins/HAL` (admin password, restarting `coreaudiod`) and hijacks the default output device. |

**Chosen: process taps.** They are Apple's supported API for this. They need no driver, add
about one IO buffer of latency, and fail safe: the tap uses `CATapMutedWhenTapped`, so the original
audio is muted only while EquAudio is actively reading it. If EquAudio stops, crashes or is
uninstalled, apps play normally again. Taps and aggregate devices are created *private* to the
EquAudio process, so nothing persists outside it.

## Verified on this machine (MacBook Pro M1, macOS 26.6.2)

Phase-1 proof of concept (`Prototype/`), run as its own app bundle:

* afplay's audio was received through a process tap, a +12 dB / 1 kHz peaking filter was applied,
  the result was played on *External Headphones* and both raw and processed signals were written
  to WAV. Measured change: **1 kHz +12.00 dB, 250 Hz +0.28 dB** (expected +12.0 / +0.3).
* The tap reports its own format (48 kHz stereo float), but inside the private aggregate it is
  delivered at the aggregate's rate (96 kHz) through drift compensation/resampling.
* In the aggregate's IOProc, input streams are ordered *sub-device inputs first, tap streams last*
  (e.g. `[6, 2]` with a 6-channel device).
* A stereo mixdown of a process that plays to a **6-channel** device (Boom's `BoomAudio`) arrives
  at exactly 1/3 amplitude (-9.54 dB). EquAudio therefore warns when the system output is a
  virtual device and offers to switch it to the physical one.
* System Audio Recording permission (TCC `kTCCServiceAudioCapture`) is tied to the code
  signature. An ad-hoc-signed rebuild shows the prompt again. Starting IO on an aggregate with input
  streams also makes coreaudiod ask TCC for the microphone service. EquAudio disables the
  non-tap input streams of its aggregates, and declares `NSMicrophoneUsageDescription` only because the
  optional "My voice" mix of the virtual mic reads the microphone (the app is terminated by macOS if a
  microphone request happens without that key).

## Components

```
 other apps' audio ──► process tap (global, excludes EquAudio, muted while tapped)
                          │
                 private aggregate device = [physical output device] + [tap]
                          │  one IOProc (C++, real-time thread)
                          ▼
   EquCore: preamp → EQ → bass/sub/harmonics → clarity/treble → loudness → width → crossfeed
            → output gain → true-peak limiter → safety clip → bypass crossfade → meters
                          │                                   │
                          ▼                                   ▼
              physical output device               lock-free SPSC ring (raw + processed)
                                                              │  recorder thread
                                                              ▼
                                                  WAV / ALAC / FLAC file (ExtAudioFile)
```

* **EquCore** (`Sources/EquCore`, C++20 behind a C API in `include/EquCore.h`): all DSP, the
  IOProc, meters and the recording ring. The audio thread never runs Swift or Objective-C code,
  allocates, locks or does I/O. Parameters are atomics, smoothed per sample or per 16-sample
  sub-block (filters use the Simper/Cytomic trapezoidal SVF, which stays stable under fast
  modulation). The graphic-EQ solver and auto-headroom run on the control thread.
* **EquAudioKit** (`Sources/EquAudioKit`, Swift): HAL wrappers, device catalogue and change
  listeners, tap + aggregate routing, engine controller (start/stop/reroute/fallback), presets,
  settings persistence, recorder, permission status, conflict detection, diagnostics and logging.
* **EquAudio** (`Sources/EquAudio`, SwiftUI): the dark UI, menu-bar extra and `--selftest` mode.

## Safety rules

* **Feedback:** EquAudio's own process is excluded from the global tap, so its output is never
  re-captured. An output device that is virtual or an aggregate (BlackHole, BoomAudio, ...) is
  never chosen automatically. Another tapping app could otherwise pick up our output and feed it
  back.
* **Double processing:** running enhancers (Boom 2/3D, eqMac, SoundSource, FxSound, ...) are
  detected by bundle ID and reported with a one-click "Quit" option. When Boom is active, apps play
  into `BoomAudio` and Boom plays its processed copy into the speakers. A global tap would capture
  both.
* **Runaway gain:** every parameter is validated and clamped. Auto headroom offsets the largest
  boost. A look-ahead true-peak limiter (on by default, -1 dBFS) and a final safety clipper
  guarantee no sample above 0 dBFS reaches the device or the recording. NaN/Inf output resets
  the DSP state.
* **When disabled or uninstalled**, nothing remains: taps and aggregates are private to the
  process and the tap mute is "muted when tapped". There is no driver to remove.

## Recording and screen recording

The recorder writes the post-processing signal: post-limiter, before the device's hardware volume
knob. Source can be *Processed* (default), *Raw system audio* (the tap input, before any
processing) or *Both* (two files), so the difference can be compared directly. See README for how
screen recorders interact with process taps. Only behaviour verified by an actual test is stated
there.

## Latency

Estimated output latency = tap/aggregate input safety offset + IO buffer (default 512 frames)
+ output safety offset + device and stream latencies + limiter look-ahead (about 1.5 ms). The
Diagnostics view shows each term as reported by the HAL, plus the input-to-output sample-time
distance measured in the IOProc.
