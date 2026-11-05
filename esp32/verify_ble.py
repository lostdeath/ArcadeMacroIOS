"""Check the first-stage ArcadeMacro bridge over the PC's Bluetooth adapter.

Requires: python -m pip install bleak
"""

import asyncio
from bleak import BleakClient, BleakScanner

SERVICE = "a8c70001-7d2b-4f4e-a5e9-8b7b5f66e001"
STATUS = "a8c70002-7d2b-4f4e-a5e9-8b7b5f66e001"
COMMAND = "a8c70003-7d2b-4f4e-a5e9-8b7b5f66e001"
RESPONSE = "a8c70004-7d2b-4f4e-a5e9-8b7b5f66e001"


async def main():
    print("Scanning for ArcadeMacro Bridge...")
    devices = await BleakScanner.discover(timeout=12)
    bridge = next((d for d in devices if d.name == "ArcadeMacro Bridge"), None)
    if bridge is None:
        raise SystemExit("Bridge not found in BLE scan")
    print(f"Found {bridge.name} ({bridge.address})")
    async with BleakClient(bridge) as client:
        if SERVICE not in [s.uuid for s in client.services]:
            raise SystemExit("Bridge service UUID missing")
        status = (await client.read_gatt_char(STATUS)).decode("utf-8")
        print(f"Status: {status}")
        await client.write_gatt_char(COMMAND, b"PING", response=True)
        reply = (await client.read_gatt_char(RESPONSE)).decode("utf-8")
        print(f"Ping response: {reply}")
        if reply != "PONG v1":
            raise SystemExit("Unexpected bridge response")
    print("BLE bridge handshake passed")


if __name__ == "__main__":
    asyncio.run(main())
