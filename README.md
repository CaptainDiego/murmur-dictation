# Murmur

A menu bar speech-to-text app for macOS. Hold the **Fn / 🌐 Globe** key, talk,
let go — the text is pasted wherever your cursor is.

Everything runs on this Mac. The only network access Murmur ever makes is a
one-time model download on first launch; after that it works with the Wi-Fi off.

- **Model:** NVIDIA Parakeet TDT 0.6B (v2, v3, Ultra, or Bark 3.0 Clean — see
  [Choosing a model](#choosing-a-model)), as CoreML
- **Runs on:** the Apple Neural Engine, via [FluidAudio](https://github.com/FluidInference/FluidAudio)
- **Speed:** ~100x realtime on an M4 — a 10 second phrase transcribes in ~0.1 s
- **Size:** ~4 MB app, ~470–600 MB of model weights cached once

## Build and install

```bash
./build.sh --install     # builds, bundles, ad-hoc signs, copies to /Applications
open -a Murmur
```

Leave off `--install` to just produce `dist/Murmur.app`.

Requires the Swift 6 toolchain from Xcode Command Line Tools. No Xcode project,
no Python, no virtualenv.

## First run

The app has no dock icon — look for the microphone in the menu bar. On first
launch it registers itself as a login item, downloads the model (~470 MB), and
asks for two permissions. **Both are required:**

| Permission | Why | Where |
|---|---|---|
| Microphone | to hear you | System Settings › Privacy & Security › Microphone |
| Accessibility | to see the Fn key, and to paste at your cursor | System Settings › Privacy & Security › Accessibility |

macOS will not let an app grant these to itself. If the prompts do not appear,
open those panes and add `/Applications/Murmur.app` by hand.

### Free up the Globe key

macOS binds Fn / 🌐 to its own action by default. Set
**System Settings › Keyboard › "Press 🌐 key to"** to **"Do Nothing"**, otherwise
the input-source switcher or Apple's own dictation fires alongside Murmur.
Settings shows a warning when it detects this.

## Using it

Hold **Fn**, speak, release. The transcript is pasted into the frontmost app and
your previous clipboard contents are put back a moment later.

A quick tap of under 0.2 s is ignored, so brushing the key does nothing. If you
press another key while holding Fn, Murmur treats it as a shortcut and throws the
audio away.

## What Murmur watches

When the trigger is a lone modifier such as Fn, Murmur installs two global event
monitors: one for modifier changes, and one for key presses. The key-press
monitor ignores the event entirely — it only notices that *some* key went down,
so it can tell "holding Fn to dictate" apart from "pressing Fn+C". No keystroke
is read, stored or sent anywhere. See `registerModifierWatch` in
`Sources/Murmur/Hotkey.swift`.

A key combination trigger uses Carbon's `RegisterEventHotKey` instead, which
installs no monitors at all and needs no Accessibility permission.

## Choosing a model

All four variants are the same 0.6B-parameter Parakeet TDT family, so any Mac
that can run one can run them all — hardware doesn't change the choice here.
(NVIDIA also ships larger 1.1B Parakeet models, but those don't have solid
Apple Silicon/CoreML ports yet, so Murmur doesn't offer them.) What should
change the choice is which language you talk in:

| You mostly dictate in | Use | Why |
|---|---|---|
| English only | **v2** | Best English accuracy (~6% WER on the Open ASR leaderboard) — beats Whisper-large while running far faster |
| Several languages | **Ultra** | 25 European languages, English about on par with v2, and more accurate than v3 at the same speed |
| Several languages, smaller download | **v3** | Same 25 languages as Ultra, slightly behind it in accuracy |
| English dictation into prose | **Bark 3.0 Clean** | English only; drops "um," false starts, and repeated words as it transcribes |

Ultra is a strict upgrade over v3 (same API, same speed, more accurate), so
prefer it unless the extra download matters. All of them run on the Neural
Engine via CoreML on any Apple Silicon Mac (M1 or later) — there's no
Intel/CoreML path, and this app won't run on one.

Any Apple Silicon Mac with a few GB of free disk space handles the model
comfortably; RAM isn't a meaningful constraint at this model size (~480–600 MB
on disk).

## Settings

Open from the menu bar icon:

- **Shortcut** — a single modifier (Fn, either Option, Right Command, Right
  Control) or any key combination. A lone modifier needs Accessibility; a
  combination such as ⌃⌥D works without it.
- **Activation** — hold to talk, or press once to start and again to stop.
- **Model** — v3 (25 languages, the default), Ultra, v2, or Bark 3.0 Clean —
  see [Choosing a model](#choosing-a-model). Switching re-downloads.
- **Transcript** — paste at the cursor, or only copy to the clipboard. Copy-only
  mode does not need Accessibility.
- **Launch at login** — on by default.

## Command line

```bash
/Applications/Murmur.app/Contents/MacOS/Murmur --status
/Applications/Murmur.app/Contents/MacOS/Murmur --transcribe recording.m4a
```

`--status` reports permissions, login item state and whether the model is cached.
`--transcribe` runs a file through the same code path the hotkey uses, which is
the quickest way to confirm the model works. Any format AVFoundation can read
is accepted.

Proof that it is offline:

```bash
sandbox-exec -p '(version 1)(allow default)(deny network*)' \
  /Applications/Murmur.app/Contents/MacOS/Murmur --transcribe recording.m4a
```

## Running the tests

```bash
swift test                                    # fast logic tests only
MURMUR_RUN_MODEL_TESTS=1 swift test           # also runs the model end to end
```

The model tests download and load whichever variant is already set in
Settings (v3 by default) and transcribe a synthesized phrase, including one
run under `sandbox-exec --deny network` to prove the offline claim — the same
check described above, just automated. They're opt-in because they need the
model on disk; everything else runs in well under a second.

`swift test` needs the `xctest` launcher, which ships with Xcode but not with
Command Line Tools alone — on a CLT-only machine the tests will compile but
`swift build --build-tests` is as far as you can verify locally; they run
normally in CI or with Xcode installed.

## A note on rebuilding

The app is signed ad-hoc, because there is no Developer ID on this machine.
macOS ties Accessibility and Microphone grants to the exact signature, so
**after a rebuild you may have to remove Murmur from those two panes and add it
back**. Signing with a real Apple Development certificate avoids this.

Murmur retries quietly in the background once Accessibility is granted, so
you don't need to restart the app after fixing permissions — but a *rebuild*
still invalidates the old grant, since it's a new binary with a new signature.

## Hardware note

A Mac mini has no built-in microphone. Pick your input under System Settings ›
Sound › Input — Murmur follows whatever that is set to.

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
| `build.sh` | builds the `.app`, generates the icon, ad-hoc signs |

FluidAudio ships text-to-speech, speaker-diarization, and text-normalization
subsystems Murmur never uses; `Package.swift` opts out of all three via its
trait system (`traits: []`), which is most of why the app is ~4 MB instead of
~15 MB.

## License

[MIT](LICENSE). Built on [FluidAudio](https://github.com/FluidInference/FluidAudio)
(MIT/Apache 2.0) and NVIDIA's open-source [Parakeet](https://huggingface.co/FluidInference)
models.
