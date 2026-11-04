# ArcadeMacro iOS

SwiftUI/Core Bluetooth utility for iPhone, with a BLE scanner, GATT service and characteristic inspector, a timed macro sequence editor, and JSON export. The GitHub Actions workflow builds the device app without a signing identity and packages the `.app` into an unsigned IPA artifact for later signing with Sideloadly.

## Build

Open `project.yml` with XcodeGen on macOS (`brew install xcodegen`, then `xcodegen generate`) and build the `ArcadeMacro` target. GitHub Actions does this on a macOS runner for pushes to `main` and manual workflow runs. Download the `ArcadeMacro-unsigned-IPA` artifact from the completed Actions run.

## Bluetooth and macro support status

The app uses CoreBluetooth to scan, connect, discover services and characteristics, and read exposed values. It intentionally has no generic write control. A safe macro upload must first read the controller's complete current settings block, change only the active profile's macro fields, and send the preserved full block back so button mappings remain intact. Bluetooth HID controllers may be managed by iOS and may not appear as app-visible BLE peripherals. Macro upload stays disabled until the actual Bluetooth read/write transport is confirmed.

The app targets iOS 15+. iPhone 13 is supported. Unsigned builds require signing before installation.
