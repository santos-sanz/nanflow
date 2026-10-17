# Nanflow

<p align="center">
  <img src="https://img.shields.io/badge/platform-macOS%2014.2%2B-black?logo=apple" alt="macOS 14.2+">
  <img src="https://img.shields.io/badge/Swift-6-blue?logo=swift" alt="Swift 6">
  <img src="https://img.shields.io/badge/tests-22%2F22-brightgreen" alt="tests 22/22">
  <img src="https://img.shields.io/badge/license-private-lightgrey" alt="license">
</p>

**Hold a key, speak, get perfectly formatted text anywhere on your Mac.**

Nanflow is a Wispr Flow–style voice dictation app for macOS. It captures your voice with a global hotkey, transcribes it with the Nan API's Whisper endpoint, polishes it with an LLM (punctuation, accents, filler removal, or a full formal/informal tone rewrite), and pastes it into whatever app you're typing in. It also detects meetings (Zoom, Teams, FaceTime, Webex, Google Meet in the browser), records their system + mic audio, and generates a transcript with a structured summary.

## Demo

| Control panel | Dictation result |
|---|---|
| ![Nanflow settings panel](docs/screenshots/settings.png) | ![Dictation pasted into TextEdit](docs/screenshots/dictation.png) |

The menu bar gives you quick control without opening the window:

![Menu bar menu](docs/screenshots/menu.png)

## Features

- **🎙️ Hold-to-talk dictation** — hold ⌘ right (configurable to ⌥ right, Fn or F5), speak, release. A floating bubble shows recording state and mic level; the polished text is pasted at your cursor.
- **🌍 Spanish & English** — language is detected per utterance; the formatter always answers in the language you spoke.
- **✨ Text styles** — choose how the LLM rewrites your speech:
  | Style | What it does | LLM call |
  |---|---|---|
  | **Off** | Pastes the raw Whisper transcript | ❌ none — minimum latency |
  | **Natural** (default) | Punctuation, accents, filler removal, verbatim meaning | ✅ |
  | **Informal** | Casual, friendly tone — like texting a teammate | ✅ |
  | **Formal** | Professional register for emails and reports | ✅ |
- **🔵 Automatic meetings** — detects meetings by app bundle ID or `meet.google.com` browser tabs, records system audio + mic, then transcribes and summarizes with decisions and action items.
- **⚡ Fast by design** — silence trimming, in-memory WAV upload, TLS prewarm, and style Off all cut end-to-end latency.
- **🔒 Privacy-first** — audio only travels to the Nan API (Whisper + LLM). Transcripts, meeting recordings and history stay on your Mac.
- **🖼️ Control panel** — a SwiftUI settings window to switch styles, hotkey, meeting behavior, check permissions and browse recent history.

## Latency

Measured end-to-end (release hotkey → text pasted), dictation clip ~7 s of speech, in-app:

| Mode | Total | Breakdown |
|---|---|---|
| Style **Off** | ~3.5 s | whisper only (upload + server) |
| Style **Natural** | ~4.1 s | whisper + LLM polish (connection prewarmed) |

Optimizations included: leading/trailing silence trim (−13 % upload), PCM16 WAV built in memory (no temp files), DNS/TLS prewarm at launch, and skipping the LLM entirely when style is Off.

## Quick start

```bash
# Build the app (requires Xcode / Command Line Tools)
./scripts/build-app.sh release
open build/Nanflow.app
```

On first launch, grant:

1. **Accessibility** — global hotkey + pasting (System Settings → Privacy & Security → Accessibility).
2. **Microphone** — capturing your voice (prompted automatically).
3. **Notifications** — meeting alerts (optional).

System audio capture uses a **Core Audio Process Tap** — it does **not** need Screen Recording permission.

## Configuration

`.env` is looked up in: `~/.nanflow/.env` → `~/Library/Application Support/Nanflow/.env` → app bundle `Resources/.env` → current directory.

```ini
NAN_API_KEY=sk-...
NAN_BASE_URL=https://api.nan.builders/v1
NAN_MODEL=qwen3.8-flash          # any non-reasoning chat model works
NAN_WHISPER_MODEL=whisper
```

## Architecture

Native Swift, no external dependencies:

```
┌─ nanflow (menu bar app) ────────────────────────────────────────────┐
│  AppDelegate · SettingsStore · SettingsView (SwiftUI) · BubblePanel │
└──────────┬──────────────────────────────────────────────────────────┘
           │
┌─ NanflowCore ───────────────────────────────────────────────────────┐
│  HotKeyMonitor (CGEventTap, dedicated thread)                       │
│  DictationEngine  ──► MicRecorder (AVAudioEngine → 16 kHz)          │
│      │  trimSilence ─► WavEncoder (in-memory PCM16)                 │
│      │             ─► NanClient.transcribe   ──►  Nan API (whisper) │
│      └── Formatter (off/natural/informal/formal) ──►  Nan API (LLM) │
│  MeetingDetector (bundle IDs + browser tabs, 2 s poll)              │
│  MeetingEngine ──► SystemAudioRecorder (Core Audio Process Tap)     │
│      │            + MicRecorder ─► AudioMixer ─► WAV on disk        │
│      └──► transcribe + summarize ─► HistoryStore (local JSON)       │
│  TextInserter (clipboard backup → ⌘V → restore)                     │
└─────────────────────────────────────────────────────────────────────┘
```

- **NanflowCore** — testable library (no GUI required)
- **nanflow** — menu bar app: status item, SwiftUI control panel, floating recording bubble
- **nanflow-cli** — GUI-free test harness

## Development

```bash
swift build -c release          # build everything
swift test                      # 22 unit tests
./scripts/build-app.sh release  # build/Nanflow.app (signed with "Nanflow Dev")

# CLI harness
.build/release/nanflow-cli env                        # config check
.build/release/nanflow-cli test-llm                   # LLM ping
.build/release/nanflow-cli transcribe /tmp/audio.wav  # whisper via Nan
.build/release/nanflow-cli pipeline /tmp/audio.wav    # transcribe + format, with timings
.build/release/nanflow-cli record-test --secs 3       # real mic → full pipeline
.build/release/nanflow-cli tap-test                   # system audio → whisper
.build/release/nanflow-cli meeting-test --secs 8      # meeting engine end-to-end
.build/release/nanflow-cli detect                     # meeting detection status
```

Runtime state lives in `~/Library/Application Support/Nanflow/` (`history.json`, `meetings/`, `nanflow.log`). Event-tap debugging: `defaults write com.nanflow.nanflow nanflow.debug.taplog -bool true`.

### Testing without a mic

```bash
say -v Monica -o /tmp/test.aiff "texto de prueba"
afconvert -f WAVE -d LEI16@16000 -c 1 /tmp/test.aiff /tmp/test.wav
# with the app running (Accessibility granted):
osascript -e 'tell application "System Events" to key down 54'
afplay /tmp/test.wav          # the mic picks up the speakers
osascript -e 'tell application "System Events" to key up 54'
tail ~/Library/Application\ Support/Nanflow/nanflow.log
```

## Troubleshooting

| Symptom | Fix |
|---|---|
| Hotkey does nothing | Accessibility permission off — re-toggle the Nanflow row. Rebuilds keep permissions thanks to the stable "Nanflow Dev" signing identity. |
| Recording but empty transcript | Mic permission, or the bubble captured silence. Check `nanflow.log`. |
| Formatting feels slow | Set style **Off**, or use a non-reasoning `NAN_MODEL` (e.g. `qwen3.8-flash`; `glm5.3-flash` thinks for 8 s+). |
| Meeting not detected | Supported: Zoom, Teams, FaceTime, Webex, Whereby, Google Meet tabs in Chrome/Edge/Brave. |
| Whisper says "en" for Spanish text | Fixed by the `looksSpanish` heuristic; text quality is unaffected. |

## Roadmap

- [ ] Meeting summary editor window
- [ ] Custom dictionary for names/terms
- [ ] Voice commands ("nueva línea", "punto y aparte")
- [ ] PDF export for meeting reports

---

Built as an educational clone of Wispr Flow. The original app (Electron) was analyzed via reverse engineering of its `app.asar` bundle to replicate feature behavior; all code here is original and Swift-native.
