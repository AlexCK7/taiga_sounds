# Taiga Sounds 🎛️🔊

A customizable Flutter soundboard app: import audio, discover sounds, and play them instantly with a clean UI and theme support.

## What this shows (recruiter version)
This project demonstrates real-world mobile engineering:
- **Audio playback & session handling** (soundboard behavior, low friction UX)
- **File import + local persistence** (user-provided audio)
- **External sound discovery** (network fetching / “discover” workflow)
- **Clean UI architecture** (multiple screens, reusable components, theme system)
- **Reliability** (linting, tests, reproducible builds, clean Git hygiene)

## Features
- 🎚️ Soundboard mode
- 🔎 Discover sounds (browse/search + import)
- 📥 Import audio files (device file picker)
- 🎨 Theme support (dark/light)
- ✅ Automated tests + clean formatting

## Tech Stack
- **Flutter / Dart**
- `just_audio`, `audio_session`
- `http`, `path_provider`, `file_picker`
- `flutter_sound` + `ffmpeg_kit_audio_flutter` (audio utilities)

## Getting Started

### Prerequisites
- Flutter SDK installed
- Android Studio / Xcode set up
- A device or emulator

Check Flutter setup:
```bash
flutter doctor
```

### Run locally
```bash
git clone https://github.com/AlexCK7/taiga_sounds.git
cd taiga_sounds
flutter pub get
flutter run
```

## Tests / Quality
```bash
flutter analyze
flutter test
dart format .
```

## Project Structure (high level)
- `lib/` — main app code (UI + logic)
- `assets/sounds/` — bundled sample sounds (if included)
- `android/`, `ios/`, `macos/` — platform build targets
- `test/` — unit/widget tests
- `screenshots/` — add screenshots here later

## Screenshots
Add screenshots to `screenshots/` and update this section later, for example:
```md
![Home](screenshots/home.png)
```

## Roadmap
- Add demo video
- Add more automated tests (audio flow + import flow)
- Improve sound editor tooling
- Add CI (GitHub Actions) for tests on every push

## License
No license specified yet. Add one if you want this to be open-source for reuse.
