# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Fuji San is a Flutter app (Windows, macOS, Android, iOS) that manages FUJIFILM X100VI film recipes and writes them to the camera's C1–C7 custom slots over native USB. No server, no accounts. User-facing strings (UI, error messages, README) are Korean; keep new ones Korean.

The project is experimental. On a real camera (X100VI firmware 1.32, Windows WPD) reading and one C1–C7 batch apply with read-back have been confirmed; restore, slot editing and every other platform are unverified on hardware. A passing build or test run says nothing about real-camera compatibility — do not claim it does in docs or commit messages.

## Commands

Flutter 3.47.6 stable is pinned in CI. `flutter`/`dart` may not be on PATH; a local SDK lives in the gitignored `.tools/flutter/bin` (`.tools/` also holds local scratch output: previews, release builds, probe results).

```sh
flutter pub get
dart run tool/sync_apple.dart --check                          # Apple Runner copies match native/apple
dart format --output=none --set-exit-if-changed lib test tool  # CI fails on unformatted code
flutter analyze
flutter test
flutter test test/camera_test.dart                             # one file
flutter test test/camera_test.dart --plain-name "batch persists backup"   # one test
flutter run -d windows
```

CI (`.github/workflows/ci.yml`) runs exactly the five checks above, then builds all four platforms. Other tools:

- `./tool/test_updater.ps1` — exercises `assets/update_windows.ps1` (install, hash rejection, zip traversal rejection, rollback) with fixture apps. Runs under Windows PowerShell 5.1 in CI.
- `flutter test tool/preview_test.dart` — local only; renders 390- and 1440-wide screenshots to `.tools/preview-*.png`.
- `fuji_san.exe --diagnose-camera out.json` / `--diagnose-slots out.json` — headless diagnostics through the same transport and model checks as the app (`lib/diagnostics.dart`). The first is read-only; the second cycles through C1–C7 and restores the original slot. `--diagnose-write-back out.json` rewrites every slot's own values and records the camera's response to each write, changing nothing.
- `windows-probe.yml` builds `wpd_probe.cpp` + `wpd_camera.cpp` standalone with `cl /W4 /WX`, so `wpd_camera.*` must stay free of Flutter dependencies and warning-clean.

## Architecture

### Layers

- `lib/domain/recipe.dart` — the `settings` table is the single schema for recipe fields: PTP property ID (`0xd190`–`0xd1a2`), allowed values or range, signedness, display scale. `Recipe` validates against it in its constructor, so an invalid recipe cannot exist. `applicable(id, values)` encodes dependencies between fields (mono-only tints, Kelvin only with Kelvin WB, DR/highlight/shadow only when DR priority is off); inapplicable fields are never written.
- `lib/camera/ptp.dart` — PTP packet framing and `NativeTransport`, which implements `CameraTransport` over the method channel.
- `lib/camera/camera.dart` — `FujiCamera` (PTP operations on a `CameraTransport`), `Snapshot` (raw property bytes of one slot), `SlotEdit` (diff of an edited slot against its snapshot), `BatchWriter` (multi-slot apply against the `RecipeCamera` interface).
- `lib/storage.dart` — `LibraryStore`: `library.json` (atomic tmp + rename) and `backup-*.json` under the application support dir's `fuji-san/` folder.
- `lib/updates.dart` — GitHub release check and the Windows self-updater.
- `lib/main.dart` — the entire UI and app state live in `_WorkspaceState`; `lib/camera_slot_editor.dart` edits a slot as currently stored on the camera.

### One method channel, two transport modes

Every platform implements channel `dev.reikop.fuji_san/usb` with `discover`, `connect`, `disconnect`, plus either raw `read`/`write` or `transaction`. `connect` returns `managedSession`:

- **false** (WinUSB, Android USB Host): Dart frames PTP containers itself, sends OpenSession/CloseSession, and reassembles packets from raw bulk reads.
- **true** (Windows WPD, Apple ImageCaptureCore): the OS owns the session. Dart still encodes the command packet, and native code unpacks it, executes it through the OS API, and returns a synthesized response packet plus data.

All protocol logic stays in Dart; native code is transport only. Native implementations: `windows/runner/fuji_usb.cpp` (channel + WinUSB fallback) and `wpd_camera.cpp` (WPD, the default Windows path with the inbox driver), `android/.../MainActivity.kt`, and `native/apple/FujiUsb.swift`.

`native/apple/FujiUsb.swift` is the source of truth for both Apple platforms. `ios/Runner/FujiUsb.swift` and `macos/Runner/FujiUsb.swift` are copies — edit the shared file, then run `dart run tool/sync_apple.dart`.

### Camera write invariants

These are the safety design of the app; preserve them when changing camera code.

- `inspect()` must succeed first: it requires manufacturer FUJI, model exactly `X100VI`, and every needed operation and property to be advertised.
- Slot properties are addressed by first selecting the slot via `0xd18c`. Every operation that changes the selected slot (`backup`, `_write`) restores the original selection in `finally` and verifies it.
- A backup is read and durably persisted to disk before any write (`BatchWriter.apply`, `editSlot`). `editSlot` also re-reads the slot and aborts if it changed since the editor opened.
- Each value is validated before being set — against the camera's property descriptor (`0x1014`), or against the `settings` table when descriptors are unavailable — and every written property is read back and compared.
- The descriptor fallback is deliberately narrow: only X100VI firmware `1.32` returning `0x2002` for `0x1014`. Other descriptor errors must still fail.
- Dynamic Range Auto is `0xFFFF` (65535) on the wire: an X100VI 1.32 stores it that way, accepts it, and refuses `0` with `0x201C`. `Recipe.fromJson` migrates the old `0`.
- The camera answers `0x201C` (invalid value) to writes of properties that do not apply to the slot's state, even with the value it already holds: mono tints for colour films, colour for mono films, Kelvin unless WB is Kelvin. This matches `applicable()`. `_write` tolerates a refused write only when the slot already holds the value, and names the property otherwise.
- Grain "Off" is written as `1` but reads back as `6`; `Snapshot.values`, the write verification, and `restore` all special-case this.
- Batch apply is sequential, stops at the first failure, and never rolls back automatically; restore is a manual user action from saved backups.
- Unknown properties (image size, quality, etc.) are never written.

### Updates and versioning

The version lives in two places that must change together: `version` in `pubspec.yaml` and `appRelease` in `lib/updates.dart` (compared against GitHub release tags; prerelease builds also see prereleases, stable builds only stable). README also states the version.

The Windows updater downloads `fuji-san-windows.zip`, checks the exact URL, size and GitHub's SHA-256 digest, then hands off to `assets/update_windows.ps1` (bundled as a Flutter asset, copied into a job directory). The script stages the new folder and signals `ready`; the app closes USB, writes a `commit` file and exits; only then does the script swap folders, keeping the old one in `.fuji-san-previous-*` and rolling back if the new exe fails to start. Other platforms only open the release page.

### Tests

Tests never touch a real device. Patterns to reuse: mock the method channel via `setMockMethodCallHandler(NativeTransport.channel, ...)`, implement `CameraTransport` or `RecipeCamera` with a fake, and pass `MemoryStore` (in `test/ui_test.dart`) as `FujiSanApp(store: ...)`. Injecting a store also disables the automatic update check. UI tests run at both 390×844 and 1440×1000 because the layout switches between mobile bottom navigation and a three-column desktop view.

`analysis_options.yaml` excludes the platform directories and `.tools/`, so analyzer/lints cover only `lib`, `test`, and `tool`.
