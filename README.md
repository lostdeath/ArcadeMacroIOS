# ArcadeMacro iOS

iPhone app for building macros for the 8BitDo Arcade Stick (model 80FE) and
saving them on the stick through an ESP32-S3 Bluetooth bridge.

- **Stick tab:** a drawing of the stick that lights up as you press real
  buttons, a connect / plug in / load checklist, the stick's two macro slots,
  and **Restore to normal** (removes all macros; button layout is untouched).
- **Macros tab:** tap buttons on the drawing to add steps (combos and joystick
  diagonals supported), choose how long each press lasts, add pauses, reorder,
  and preview the sequence.
- **Put on stick:** pick the trigger button (P1, P2 or a face button) and the
  macro slot, then send. The bridge writes only the macro section and reads it
  back to verify.
- **Advanced tab:** raw Bluetooth scanner and diagnostics.

## Build

Open `project.yml` with XcodeGen on macOS (`brew install xcodegen`, then `xcodegen generate`) and build the `ArcadeMacro` target. GitHub Actions does this on a macOS runner for pushes to `main` and manual workflow runs. Download the `ArcadeMacro-unsigned-IPA` artifact from the completed Actions run.

## Bluetooth and macro support status

The app uses CoreBluetooth to scan, connect, discover services and characteristics, and read exposed values. It intentionally has no generic write control. A safe macro upload must first read the controller's complete current settings block, change only the active profile's macro fields, and send the preserved full block back so button mappings remain intact. Bluetooth HID controllers may be managed by iOS and may not appear as app-visible BLE peripherals. Macro upload stays disabled until the actual Bluetooth read/write transport is confirmed.

The app targets iOS 15+. iPhone 13 is supported. Unsigned builds require signing before installation.

## ESP32-S3 bridge

The first-stage ESP32-S3 firmware and flashing instructions are in
[`esp32/README.md`](esp32/README.md). The iPhone Bluetooth screen recognizes
its custom service, reads bridge status, and can send a `PING` command. This
only verifies the phone-to-board BLE link; the stick transport and macro
upload still require the exact controller model and protocol.
