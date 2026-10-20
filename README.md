# EquAudio — system-wide audio enhancer for macOS (Apple Silicon)

Processes the audio of every app (Safari, Spotify, Music, games, video) with a 10-band EQ, bass/sub-bass/harmonics,
clarity, treble, loudness, stereo width, headphone crossfeed and a look-ahead limiter, and can record the processed output.
Local only — nothing is uploaded.

## How it works
Core Audio **process taps** (macOS 14.2+, no driver, no admin password): EquAudio taps all other apps' output (muted while
tapped), processes it in a C++ real-time IOProc and plays it on your real output device. Stop or quit EquAudio and apps
play normally again — nothing stays installed system-wide. Its own audio is excluded from the tap (no feedback).

## Quick start
```
./setup.sh      # checks macOS / Command Line Tools (install: xcode-select --install)
./build.sh      # builds + signs ./EquAudio.app in ~/Library/Caches/EquAudio/build/app
./run.sh        # launches it
./install.sh    # copies it to /Applications
./test.sh       # unit tests (DSP, params, presets)
```
On first launch macOS asks for **System Audio Recording** permission — click Allow. (The app is signed with a fixed identity requirement, so you approve once and rebuilds keep it. After each
update it is remembered. Manage it in System Settings → Privacy & Security → Screen & System Audio Recording.)

## Using it
Pick a preset (Flat, Balanced, Bass Boost, Deep Bass, Vocal Clarity, Treble Detail, Warm, Rock, Electronic, Classical,
Movies, Gaming, Headphones, …), drag the EQ sliders (double-click resets a band), use **Bypass** for A/B. *Save…* stores
your own presets. **Record** writes the processed signal (post-limiter) to WAV/ALAC/FLAC in the chosen folder.

## Visualizer
The **CONTROLS | VISUALIZER** switch in the top bar (⌘1 / ⌘2) opens a page with five live views at once. They are driven by an 8192-point FFT of the live
output (and of the input before processing): **Spectrum** (72 log bands with peak holds), **Impact** (input vs output curves plus the measured change in
bass / mids / highs, i.e. what your EQ and bass effects really do), **Scope** (waveform + stereo vectorscope that shows Ambience / 3D Spatial width),
**Radial** (bass-reactive circle with rings on bass hits) and **Waterfall** (spectrogram). The analysis only runs while that page is open.

## Touch Bar and shortcuts
A small live **level line** (in the theme colours) sits in the Touch Bar's Control Strip and stays visible in every app. Tap it to open the full
EquAudio Touch Bar (level line, Intensity and Bass sliders, preset picker, A/B, power; ✕ closes it). While EquAudio is frontmost the same
controls show in its own Touch Bar. The Touch Bar shows the LED meter, a scrolling output-level line and a Bass slider. The Control Strip and pop-up bar use private macOS Touch Bar calls (the ones MTMR/Pock use); if a future
macOS removes them the app logs it and keeps working without the Touch Bar. Shortcuts: ⌘B A/B original, ⇧⌘P power, ⌥⌘T Touch Bar controls. If the Control Strip item ever disappears, Audio ▸ Restore Touch Bar Item puts it back (the app also re-adds it automatically every few seconds and when you return to it).
The window resizes (minimum 1080x760) and goes full screen (⌃⌘F): the EQ and level displays grow while text and controls stay sharp. The bottom bar shows what is playing (title, artist, cover art, app) for any app that reports it to macOS — Music, Spotify, browser tabs — read through a private MediaRemote call run inside /usr/bin/perl (needed on macOS 15.4+); if it stops working that card just says "Nothing playing". In the window you can also drag directly on the EQ curve, and switch colour themes with the THEME button.

## Virtual mic (play an app's audio into Discord/Zoom/OBS, equalized)
macOS can't create a microphone without a driver, so this needs the free **BlackHole 2ch** loopback driver (GPL-3.0):
`brew install --cask blackhole-2ch` (asks for your admin password; the app has a "Copy install command" button), then reopen EquAudio.
In the **Virtual mic** card pick a source (All system audio, or an app that is playing audio, e.g. Chrome, Spotify) and switch it on,
then choose **BlackHole 2ch** as the microphone in your chat app. The audio goes through the same EQ/bass/reverb settings you hear
(plus a Level slider). The original keeps playing for you. Limit: it works **per app, not per browser tab** (Chrome plays all tabs through
one audio process; use a different browser or "All system audio" if you need to separate them).

**Mixer (Virtual mic tab):** *Music* sets the app's level in the mic; *My voice* mixes your real microphone in (pick the microphone, set
its level, MUTE it, and optionally *Duck music while I talk*, which lowers the music by up to 12 dB while you speak). Both go through the
limiter so the sum never clips. Meters show what is being sent (SEND) and what the mic hears (MIC). *My volume* (Output card) changes only
what you hear. The first time you switch *My voice* on, macOS asks for Microphone access (System Settings → Privacy & Security → Microphone).
Use headphones, otherwise your mic picks up the music and friends hear it twice. Uninstall the driver with `brew uninstall --cask blackhole-2ch`.

**Discord says "isn't detecting any input"?** Its voice filters treat music as noise. In Discord → Voice & Video turn **off** Noise Suppression,
Echo Cancellation and Automatic Gain Control, and turn off "Automatically determine input sensitivity". (Verified: the audio does arrive on the BlackHole input.)

## Troubleshooting
- **No sound change / "no audio received"**: allow System Audio Recording (button in the status bar).
- **Boom 2/3D, eqMac, SoundSource running**: quit them — otherwise audio is processed twice. If the system output is a
  virtual device (e.g. *BoomAudio*), EquAudio plays on the physical device instead, and apps' audio arrives lower (6-ch virtual devices
  down-mix); set the real device as system output in System Settings → Sound.
- **Crackles**: raise the buffer size in settings.json (`bufferFrames`, default 512).
- Logs: `~/Library/Logs/EquAudio/EquAudio.log`

## Verified on this Mac (M1, macOS 26.6)
- afplay tone → tap → EQ → speakers: a +9 dB band measured **+9.00 dB** at the output (`Prototype/`, `docs/poc-evidence/`, and the app's `--selftest`).
- 14 unit tests pass (parameters, EQ band gain, limiter ceiling, headroom, bypass exactness, NaN safety, random-parameter stability).
- Not verified: recording UI path on a live session, screen-recorder interaction (QuickTime/OBS) with the processed signal,
  Bluetooth devices. AI/neural enhancement was evaluated and **not included** (speech denoisers damage music).

## Uninstall
`./uninstall.sh` (add `--dry-run` first). Removes the app, settings, logs, permission entries; never touches your recordings.
