# Changelog

## 2.0.2 - 2026-10-27

### Changed

- Centralized legacy-only compatibility identifiers in the read-only migration module.
- Rebuilt the public repository with a clean single-commit history.
- Clarified the supported Swift build toolchain and expanded the regression summary.

## 2.0.1 - 2026-10-26

### Changed

- Relicensed the project under MIT.
- Replaced the private-development Bundle ID, data directory, Keychain service, and dispatch labels with neutral public identifiers.
- Added a one-time copy migration from the pre-public v2 data directory and Keychain service.
- Removed the built-in domain-specific terminology context; terminology hints now come only from user settings.
- Made the public packaging script self-contained and removed company-specific test fixtures.

## 2.0.0 - 2026-10-26

### Changed

- Renamed the product, app bundle, windows, settings, data directory, archives, and documentation to Meeting Copilot.
- Kept legacy Foresight names only for read-only data/path/keychain migration.

### Added

- macOS Core Audio Tap capture for system audio, using the "System Audio Recording Only" permission.
- Microphone, system audio, and dual-source capture modes.
- Local Qwen3-ASR and Apple on-device speech options.
- Independent local/network selection for transcription and translation.
- OpenAI-compatible network transcription and translation adapters.
- Meeting minutes, action items, and question answering through a separate compatible Chat Completions endpoint.
- Meeting materials, Markdown/JSON export, floating HUD, and quick notes.

### Fixed

- Convert interleaved stereo Float32 from Core Audio Tap into planar Float32 before recognizer ingress.
- Increase the PCM ingress queue from 32 to 1024 blocks so a 10 ms/48 kHz stream does not overflow before an 8-second segment completes.
- Preserve the loaded Qwen engine when a successful settings test is saved and the settings window closes.

### Verified

- Real GUI system-audio capture for approximately 48 seconds.
- Two complete transcript segments persisted and read back after app restart.
- Nine Swift regression checks passing.
