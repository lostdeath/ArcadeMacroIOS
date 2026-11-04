# ArcadeMacro iOS

SwiftUI/Core Bluetooth utility for iPhone, with a BLE scanner, GATT service and characteristic inspector, a timed macro sequence editor, and JSON export. The GitHub Actions workflow builds the device app without a signing identity and packages the `.app` into an unsigned IPA artifact for later signing with Sideloadly.

## Build

Open `project.yml` with XcodeGen on macOS (`brew install xcodegen`, then `xcodegen generate`) and build the `ArcadeMacro` target. GitHub Actions does this on a macOS runner for pushes to `main` and manual workflow runs. Download the `ArcadeMacro-unsigned-IPA` artifact from the completed Actions run.

## Bluetooth and macro support status

The app uses CoreBluetooth to scan, connect, discover services and characteristics, read exposed values, and perform an explicit raw write only when the selected characteristic advertises write support. Bluetooth HID controllers may be managed by iOS and not appear as app-visible BLE peripherals. The 8BitDo macro packet format is not verified, so the app does not claim to upload edited macros; the editor stores timed button steps locally and exports JSON. Do not write guessed bytes to the controller. Confirm the controller's actual service/characteristic and protocol before adding macro encoding.

The app targets iOS 15+. iPhone 13 is supported. Unsigned builds require signing before installation.
