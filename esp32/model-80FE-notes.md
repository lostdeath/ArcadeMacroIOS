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

Sources:

- Owner's Windows USB and HID observations, 2026-11-05.
- Static inspection of official 8BitDo Windows software: ZIP SHA-256
  `01dab0c15e7a830caf5d43ce932a6a6ebca66b0d627698dab661ca23eef3d149`,
  executable SHA-256 `56c50445ea8733e119bcc3e0bdfa02566972a47c63f4e4905ad93e5b9cd0a25e`,
  DLL SHA-256 `dd56c6e70b9bfb48fc138356f14b0267c3ca146570d45af9afbc960ab32645e5`.
