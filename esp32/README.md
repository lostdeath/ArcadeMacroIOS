# ESP32-S3 BLE bridge and read-only USB host test

This firmware is for the ESP32-S3-DevKitC-1-N16R8. It creates an iPhone-visible
BLE service named **ArcadeMacro Bridge**. Firmware v2 also starts the ESP32-S3
USB host and recognizes a USB HID gamepad. It reads gamepad input reports for
diagnostics; it does not change the 8BitDo stick's settings.

## Flash with Arduino IDE

1. Install Arduino IDE and Espressif's **esp32** board package.
2. Connect the board's **COM/UART** port to the PC with a data-capable USB cable.
   This also powers the ESP32. Note the new COM port in Windows Device Manager.
3. Open `ArcadeMacroBridge/ArcadeMacroBridge.ino`.
4. Choose **ESP32S3 Dev Module**, **16MB Flash**, **USB-OTG (TinyUSB)** for USB
   Mode, **Disabled** for USB CDC On Boot, and the new COM port. The sketch
   does not require PSRAM. Set a 16MB partition scheme such as **16M Flash
   (3MB APP/9.9MB FATFS)**.
5. Upload, then open Serial Monitor at **115200 baud**. It should print
   `BLE advertising as ArcadeMacro Bridge`.
   The board's large RGB LED glows dim blue while advertising, green when a
   phone is connected, and cyan when a USB gamepad is detected. Purple means
   USB host initialization failed. The separate red power LED stays on.
   This sketch targets RGB LED GPIO48, used by the original DevKitC-1 and the
   owner's AITRIP-style board; official v1.1 boards use GPIO38 instead.
6. In a build of the iPhone app containing bridge support, scan and connect
   to **ArcadeMacro Bridge**. The bridge status should read
   `READY v2; USB=HOST_READY_NO_GAMEPAD; STICK_WRITES=DISABLED` before a USB
   gamepad is attached. Tap **Ping bridge**;
   the response should be `PONG v1`.

For an independent PC check, install `bleak` with `python -m pip install bleak`
and run `python esp32/verify_ble.py` from the project root. It scans for the
bridge, reads status, sends `PING`, and requires `PONG v1`.

If no serial port appears, try another data-capable cable. The **USB** port is
reserved for the host connection and is not the serial monitor in this build.

## BLE protocol v1

All values are UTF-8 text. Service `A8C70001-7D2B-4F4E-A5E9-8B7B5F66E001`
contains:

| Characteristic suffix | Properties | Meaning |
| --- | --- | --- |
| `0002` | Read, Notify | Board and USB host status |
| `0003` | Write with response | `PING`, `STATUS`, `READ` or `WRITE` command |
| `0004` | Read, Notify | Command response (`READ OK 564`, `WRITE OK`, `... ERR <reason>`) |
| `0005` | Read, Notify | Live stick input (first 12 bytes of each changed report) |
| `0006` | Read, Write, Notify | Settings block transfer: `[offset lo, offset hi, up to 16 bytes]` |

The full UUID of each characteristic is the service UUID with the first group
changed to `A8C70002`, `A8C70003`, or `A8C70004`. Any other command receives
`ERR UNKNOWN_COMMAND`. Firmware v3 adds `READ` (switch the stick to config mode,
read and CRC-check the 564-byte settings block, stream it on `0006`) and `WRITE`
(write the block uploaded on `0006`). `WRITE` only proceeds after a `READ`, rejects
any change outside the two macro sections, recomputes the CRC, saves, and reads
the block back to verify. `stick_settings.py` exercises both from a PC.

## USB host connection

The 80FE stick appeared on the owner's PC as `057E:2009` USB HID in S mode and
`045E:028E` Xbox 360 controller in X mode. Use S mode for the first host test.
USB host operation requires a separate 5 V supply for the stick. Power the
ESP32 through **COM/UART**, connect its **USB** data port to a suitable powered
USB host adapter or hub, and connect the stick to that powered setup. Confirm
the connector roles before cabling; a plain USB-C cable may leave both ends
acting as devices and provide no power to the stick.

With the host connection working, status changes to
`READY v2; USB=HID_GAMEPAD_CONNECTED; STICK_WRITES=DISABLED`. The COM/UART serial
monitor prints the first 16 bytes of changed input reports. Controller settings
writes remain disabled until the complete settings block and command protocol
are established.
