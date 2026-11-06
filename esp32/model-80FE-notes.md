# 8BitDo Arcade Stick 80FE: USB observations

Observed on the owner's Windows PC on 2026-11-05 with a wired USB-C connection:

| Stick mode | Windows USB identity | Device class |
| --- | --- | --- |
| X | `045E:028E` | Xbox 360 controller (`xusb22.inf`, vendor-specific USB) |
| S | `057E:2009` | Nintendo Pro Controller compatible USB HID (`input.inf`) |

In S mode, `hidapi` reported one HID gamepad collection (usage page `0x01`,
usage `0x04`) with a 206-byte report descriptor, SHA-256
`3dd130ee714468263b6d9e915133089f79846df5b386b5897afebe6981fce514`.
The descriptor declares input reports `0x30`, `0x21`, `0x81` and output reports
`0x01`, `0x10`, `0x80`, `0x82`. These are descriptor facts only; they do not
identify the 8BitDo settings command protocol.

The official Windows Ultimate Software package downloaded for this model
contains a .NET application and native `8BitDoAdvance.dll`. Static inspection
found native exports `_readArcadeStick@4` and `_writeArcadeStick@564`. The .NET
`ArcadeStickAdvance.readAdvance` method opens a HID device and calls
`readArcadeStick`; its write path calls `writeArcadeStickDLL`. The current
evidence does not establish packet bytes, settings layout, or a safe write
procedure. Controller writes remain disabled.

The next bridge firmware stage should enumerate `057E:2009` over the ESP32-S3's
USB host interface, then expose read-only connection and descriptor status over
the existing BLE service. A powered USB host connection is required. Do not
connect the stick to the board's UART/programming port.

Cable check on 2026-11-05: the ESP32 remained reachable over BLE and reported
`USB=HOST_READY_NO_GAMEPAD`; the stick did not light up. The owner then clarified
that the stick had been connected to the board's COM/UART port. That port is a
USB-to-serial interface, so this check says nothing about whether the board's
native USB port can power or enumerate the stick. The native USB port still
needs a separate physical test with the board powered through COM/UART.

Corrected physical test later the same day: COM/UART was used for board power
and the stick was connected to the board's native USB port in S mode. The stick's
lights came on, but the bridge still reported `USB=HOST_READY_NO_GAMEPAD`.
Serial diagnostics after reset showed `USB host started` and BLE advertising,
with no gamepad mount event. This establishes a powered board and running host
stack, but does not establish whether the stick received USB VBUS or whether
the cable established the correct USB host role. The cable/adapter type needs
to be identified before attributing the failure to firmware or power.

Successful host test on 2026-11-06: a second AITRIP-style N16R8 board was
flashed over CH343 COM16 with bridge firmware v2. The owner closed the board's
back-side `USB-OTG` solder jumper, left its front-side `IN-OUT` jumper alone,
powered COM from the PC, and connected the stick to the native USB port in S
mode. BLE status changed to `USB=HID_GAMEPAD_CONNECTED`; serial output showed
changing 64-byte HID input reports beginning with report ID `0x30` while the
owner moved the joystick and pressed buttons. This proves USB enumeration and
read-only input transfer on that board and connection. It does not establish
the 8BitDo settings write protocol or that every direct USB-C cable works.

iPhone live-input test on 2026-11-06: with the same board and wiring, the
ArcadeMacro iPhone app built from commit `e710dd9` connected to the bridge,
showed `USB=HID_GAMEPAD_CONNECTED`, and its "Live stick input (hex)" line
changed as the owner moved the stick and pressed buttons. This proves
stick -> ESP32 USB host -> BLE notify (`a8c70005`) -> iPhone for read-only
input. The bridge does not present itself to iOS as a game controller, so games
do not see this input. Controller settings writes remain disabled.

## Settings protocol (decoded 2026-11-06)

Sources: USB captures of the official software syncing profile "New01", and the
decompiled .NET types `ArcadeStickAdvance`, `BasicAdvanceUIData`,
`Advance.Hid.Switch`. Bridge firmware v3 reproduces all 27 captured OUT packets
byte-for-byte.

Entering config mode (stick in S mode, `057E:2009`, interrupt OUT, 64 bytes):
`01 66 AA 00 21 01` (version) -> reply `81 66 A5 90 1A ...`; then
`01 66 AA 00 51 01` (changeDinput) -> stick re-enumerates as `2DC8:901A`.
**Never send `01 66 AA 00 50 01`: that is `boot_CMD` (firmware-update mode).**

Config mode packets (`2DC8:901A`, 64-byte interrupt OUT/IN):
`81, 17+n, 04, cmd, CC x7, n, CC, 34 02 (total 564 LE), off LE, CC CC, data[n]`
with n <= 45. `cmd 0C` = read chunk (reply `02 04 04 00 00 00 0C ...`, data at
byte 18), `0B` = write chunk, then `81 11 04 06 00 00 00 15` = save (reply cmd 06).

Block (564 bytes): u16 CRC (CRC-16 reflected poly 0x1021, init 0xFFFF, over
bytes 2..563, little-endian), u8 struct_ver, u8 platform (0 = Switch slot,
1 = Windows slot), then 2 slots x 280 bytes: u32 flag `0x20191212`, 32-byte
UTF-16 name, macro_fun (u32 flag, u8 count, pad, 2 x {u32 trigger, u16 ms[18],
u16 buttons[18], u8 steps, pad}), map_key (u32 flag, u32 key[18]).
Button bits: A 0x2000, B 0x1000, X 0x10, Y 0x20, L1 0x400, R1 0x800, L2 0x4000,
R2 0x8000, L3 0x2, R3 0x4, SELECT 0x8, START 0x1, STAR 0x10000, HOME 0x20000,
UP 0x200, DOWN 0x100, LEFT 0x80, RIGHT 0x40, P1 0x2000000, P2 0x4000000.

First macro write on 2026-11-06 through the bridge: P1 -> A, wait, B, wait, A
(100 ms each) written to slot 0 of profile "New01", saved, and read back
identical; mappings unchanged. Use `stick_settings.py --clear-macros` (or the
app's "Restore to normal") to remove macros.

Sources:

- Owner's Windows USB and HID observations, 2026-11-05.
- Static inspection of official 8BitDo Windows software: ZIP SHA-256
  `01dab0c15e7a830caf5d43ce932a6a6ebca66b0d627698dab661ca23eef3d149`,
  executable SHA-256 `56c50445ea8733e119bcc3e0bdfa02566972a47c63f4e4905ad93e5b9cd0a25e`,
  DLL SHA-256 `dd56c6e70b9bfb48fc138356f14b0267c3ca146570d45af9afbc960ab32645e5`.
