# Contributing to EquAudio

Thanks for helping out. This project is small on purpose, so the process is too.

## Before you start

- **Bugs and ideas:** open an [issue](https://github.com/githubhyno/equaudio/issues/new/choose) first
  for anything bigger than a typo, so we agree on the direction before you spend time on it.
- **Questions about how it works:** read [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md). It explains
  why process taps were chosen, what was measured and the safety rules.

## Setting up

You need an Apple Silicon Mac on macOS 14.2+ and the Xcode Command Line Tools. No Xcode project is needed.

```sh
git clone https://github.com/githubhyno/equaudio.git
cd equaudio
./setup.sh    # checks the toolchain, installs nothing
./build.sh    # builds and signs EquAudio.app
./run.sh      # launches it
./test.sh     # unit tests; needs no audio permission or devices
```

Keep the repository **out of iCloud Drive** (or any synced folder) while you work: macOS adds
Finder metadata to app bundles there and code signing fails. `build.sh` works around it for the
build output, but a `.git` folder in iCloud can still get corrupted.

## Rules for the audio code

`Sources/EquCore` runs on the real-time audio thread. In that code:

- **No allocation, no locks, no I/O, no Swift or Objective-C calls.** Not even "just once".
- Parameters are atomics, smoothed per sample or per sub-block. Do not add a parameter that
  can step the signal.
- Everything that reaches the output must stay below 0 dBFS. The limiter and the safety clipper
  are not optional, and NaN/Inf must reset the DSP state.

If you touch DSP, add or update a test in `Tests/EquCoreTests`.

## Pull requests

1. Branch from `main` and keep the change focused: one fix or feature per PR.
2. Run `./test.sh`. It must pass.
3. Match the surrounding code: naming, comment density and idiom.
4. Say what you changed and why in the PR description. For anything visible in the UI, add a screenshot.
5. If behaviour changes, update the README and add a line under *Unreleased* in [CHANGELOG.md](CHANGELOG.md).

Only claim what you have tested. The README separates what was verified from what was not, and
new claims should keep to that.

## Reporting a bug

Include your macOS version, your Mac model, what you expected and what happened, and the tail of
`~/Library/Logs/EquAudio/EquAudio.log`. Please check the
[troubleshooting section](README.md#troubleshooting) first, especially if another audio enhancer
(Boom, eqMac, SoundSource) is running.

## License

By contributing you agree that your contribution is licensed under the [MIT License](LICENSE).
