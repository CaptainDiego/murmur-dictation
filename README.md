# Murmur

A menu bar speech-to-text app for macOS. Hold **⌥D**, talk, let go — the text
is pasted wherever your cursor is. The shortcut is yours to change in Settings.

Everything runs on this Mac, on the Neural Engine. The only network access
Murmur ever makes is a one-time model download on first launch — after that
it works with the Wi-Fi off.

## Why not just use Apple's Dictation?

Fair question — macOS already has one built in. Two concrete differences:

- **Push-to-talk.** Apple's dictation shortcut is customizable, but it's
  toggle-only: press to start, and it stops on its own after a pause. Murmur
  listens only while you hold the key down, so it never catches a sentence
  you didn't mean to dictate.
- **Unconditionally local.** Apple's on-device claim is real, but conditional:
  it only runs locally on Apple Silicon, and only in the languages Apple
  supports for on-device processing — otherwise, or on an Intel Mac, your
  audio [goes to Apple's servers](https://support.apple.com/guide/mac-help/use-dictation-mh40584/mac).
  Murmur runs the same open-source Parakeet model locally on any Apple
  Silicon Mac, in any of the ~25 languages it supports, full stop — and the
  whole pipeline is open source, so that claim is checkable rather than
  taken on faith.

On raw accuracy, Parakeet TDT is independently benchmarked — v2 scores
~6% WER on the [Open ASR Leaderboard](https://huggingface.co/spaces/hf-audio/open_asr_leaderboard),
the first model to break the 7% barrier there. Apple doesn't publish
comparable numbers for Dictation, so there's no honest head-to-head claim
to make on that front.

## Install

1. Download `Murmur.dmg` from [Releases](../../releases/latest).
2. Open it and drag **Murmur** into **Applications**.
3. Open Murmur from Applications. It isn't notarized, so the first time macOS
   will block it — go to **System Settings › Privacy & Security** and click
   **Open Anyway**, then open it again.
4. Grant the **Microphone** and **Accessibility** prompts when they appear —
   both are required.

The app has no dock icon; look for it in the menu bar. It registers itself to
launch at login and downloads the model (~470 MB) on first run.

## Using it

Hold **⌥D**, speak, release. The transcript is pasted into the frontmost app
and your previous clipboard contents are restored a moment later. A tap
under 0.2 s is ignored, so brushing the key does nothing.

Want a different shortcut? Open **Settings** from the menu bar icon and set
any key or key combination — including a lone modifier like Fn, if you'd
rather free up both hands from needing a letter key.

## Settings

Open from the menu bar icon:

- **Shortcut** — any key combination (like the default ⌥D), or a single
  modifier on its own (Fn, either Option, Right Command, Right Control). A
  combination needs no extra permission; a lone modifier needs Accessibility
  to be heard system-wide.
- **Activation** — hold to talk, or press once to start and again to stop.
- **Model** — see [Choosing a model](#choosing-a-model) below. Switching
  re-downloads.
- **Transcript** — paste at the cursor, or only copy to the clipboard.
- **Launch at login** — on by default.

## Choosing a model

All variants are the same 0.6B-parameter Parakeet TDT family on any Apple
Silicon Mac (M1 or later; no Intel support) — pick by language, not hardware:

| You mostly dictate in | Use | Why |
|---|---|---|
| English only | **v2** | Best English accuracy — beats Whisper-large while running far faster |
| Several languages | **Ultra** | 25 languages, more accurate than v3 at the same speed |
| Several languages, smaller download | **v3** (default) | Same 25 languages as Ultra, slightly behind it in accuracy |
| English dictation into prose | **Bark 3.0 Clean** | English only; drops "um," false starts, and repeated words |

Ultra is a strict upgrade over v3, so prefer it unless the extra download
matters.

## Building from source

Requires the Swift 6 toolchain from Xcode Command Line Tools — no Xcode
project, no Python.

```bash
./build.sh --install     # build, bundle, ad-hoc sign, copy to /Applications
./build.sh --dmg         # same, plus dist/Murmur.dmg for distribution
```

The app is signed ad-hoc (no Developer ID on this machine), and macOS ties
permission grants to the exact signature — **after a rebuild you may have to
remove Murmur from the Microphone/Accessibility panes and re-add it.**
Murmur retries in the background once Accessibility is granted, so a restart
isn't needed, just a fresh grant.

```bash
/Applications/Murmur.app/Contents/MacOS/Murmur --status
/Applications/Murmur.app/Contents/MacOS/Murmur --transcribe recording.m4a
sandbox-exec -p '(version 1)(allow default)(deny network*)' \
  /Applications/Murmur.app/Contents/MacOS/Murmur --transcribe recording.m4a   # proves it's offline
```

```bash
swift test                            # fast logic tests
MURMUR_RUN_MODEL_TESTS=1 swift test    # + real model, incl. an offline run
```

(`swift test` needs the `xctest` launcher, which ships with Xcode but not
Command Line Tools alone — on a CLT-only machine `swift build --build-tests`
is as far as you can verify locally; both run normally in CI or with Xcode.)

## Layout

| File | Role |
|---|---|
| `Sources/Murmur/AppDelegate.swift` | menu bar item, state machine, dictation flow |
| `Sources/Murmur/Hotkey.swift` | Carbon hot key for combos, event monitor for lone modifiers |
| `Sources/Murmur/Recorder.swift` | AVAudioEngine capture, mixed to mono |
| `Sources/Murmur/Transcriber.swift` | Parakeet model loading and inference, pinned to the ANE |
| `Sources/Murmur/Paster.swift` | clipboard save, synthetic ⌘V, clipboard restore |
| `Sources/Murmur/PreferencesWindow.swift` | the settings window |
| `Sources/Murmur/SelfTest.swift` | `--status` and `--transcribe` |
| `Tests/MurmurTests/` | fast logic tests, plus opt-in model/offline integration tests |
| `build.sh` | builds the `.app`, generates the icon, ad-hoc signs, optional DMG |

For a lone-modifier trigger like Fn, Murmur installs a global event monitor
that only notices *that* a key went down, never which one — no keystroke is
read, stored, or sent anywhere (`registerModifierWatch` in `Hotkey.swift`). A
key-combination trigger uses Carbon's `RegisterEventHotKey` instead, which
needs no such monitor and no Accessibility permission.

FluidAudio ships text-to-speech, speaker-diarization, and text-normalization
subsystems Murmur never uses; `Package.swift` opts out of all three via its
trait system (`traits: []`), which is most of why the app is ~3.3 MB instead
of ~15 MB.

## License

[MIT](LICENSE). Built on [FluidAudio](https://github.com/FluidInference/FluidAudio)
(MIT/Apache 2.0) and NVIDIA's open-source [Parakeet](https://huggingface.co/FluidInference)
models.
