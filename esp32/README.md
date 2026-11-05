# ESP32-S3 BLE bridge: first connection test

This firmware is for the ESP32-S3-DevKitC-1-N16R8. It creates an iPhone-visible
BLE service named **ArcadeMacro Bridge**. This first stage tests the phone-to-board
link only. The board does not yet connect to or change the 8BitDo stick.

## Flash with Arduino IDE

1. Install Arduino IDE and Espressif's **esp32** board package.
2. Connect the board with a data-capable USB cable. On a two-port DevKitC-1,
   use the port labelled **USB** or **UART** for the first flash; note which
   serial port appears in Windows Device Manager.
3. Open `ArcadeMacroBridge/ArcadeMacroBridge.ino`.
4. Choose **ESP32S3 Dev Module**, **16MB Flash**, **8MB PSRAM**, and the new
   serial port. Leave other options at board defaults.
5. Upload, then open Serial Monitor at **115200 baud**. It should print
   `BLE advertising as ArcadeMacro Bridge`.
6. In a build of the iPhone app containing bridge support, scan and connect
   to **ArcadeMacro Bridge**. The bridge status should read
   `READY v1; USB=NOT_CONNECTED; STICK_WRITES=DISABLED`. Tap **Ping bridge**;
   the response should be `PONG v1`.

For an independent PC check, install `bleak` with `python -m pip install bleak`
and run `python esp32/verify_ble.py` from the project root. It scans for the
bridge, reads status, sends `PING`, and requires `PONG v1`.

If no serial port appears, try the other USB port and another data-capable
cable. This sketch does not use the native USB port as a host yet.

## BLE protocol v1

All values are UTF-8 text. Service `A8C70001-7D2B-4F4E-A5E9-8B7B5F66E001`
contains:

| Characteristic suffix | Properties | Meaning |
| --- | --- | --- |
| `0002` | Read | Board status |
| `0003` | Write with response | `PING` or `STATUS` command |
| `0004` | Read, Notify | Command response |

The full UUID of each characteristic is the service UUID with the first group
changed to `A8C70002`, `A8C70003`, or `A8C70004`. Any other command receives
`ERR UNKNOWN_COMMAND`. No macro upload command exists in this version.

## Next hardware step

After identifying the exact arcade stick model, inspect its USB descriptors
and settings protocol. USB host operation requires a 5 V supply for the stick;
the DevKitC-1's native USB connector alone does not establish a powered host
setup. Keep the controller settings write path disabled until its complete
settings block can be read and preserved.
