# Changelog

All notable changes to EquAudio are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/).

## [Unreleased]

## [1.0.1] - 2026-10-23

### Changed
- The output-level line in the window and on the Touch Bar, and the Impact curves and waveform in the
  visualizer, are now drawn as smooth curves instead of straight segments between samples.

## [1.0.0] - 2026-10-20

First public release.

### Added
- System-wide processing of every other app's audio through Core Audio process taps
  (macOS 14.2+, Apple Silicon): no driver, no admin password, nothing installed system-wide.
- Real-time C++20 DSP engine (`EquCore`): 10-band EQ, bass, sub-bass and bass harmonics, clarity,
  treble, loudness, stereo width, headphone crossfeed, ambience, reverb and 3D spatial, followed by
  a look-ahead true-peak limiter and a final safety clipper.
- Presets (Flat, Balanced, Bass Boost, Deep Bass, Vocal Clarity, Treble Detail, Warm, Rock,
  Electronic, Classical, Movies, Gaming, Headphones and more) and your own saved presets.
- Live visualizer: spectrum, input-vs-output impact, scope and vectorscope, radial and waterfall.
- Recorder for the processed signal (WAV, ALAC, FLAC), with raw and processed sources.
- Virtual mic for Discord, Zoom and OBS (needs the separately installed BlackHole 2ch), with a
  microphone mix and music ducking.
- Touch Bar support, now-playing card, menu-bar item and six colour themes.
- `build.sh`, `run.sh`, `install.sh`, `uninstall.sh`, `test.sh` and `scripts/make-dmg.sh`.
- 33 unit tests in 11 suites.

### Notes
- The app is signed ad-hoc and **not notarized**, so macOS asks you to approve it once on first
  launch. See the README for the steps.
- Release builds contain arm64 code only.

[1.0.0]: https://github.com/githubhyno/equaudio/releases/tag/v1.0.0
[1.0.1]: https://github.com/cutiecurses/equaudio/releases/tag/v1.0.1
