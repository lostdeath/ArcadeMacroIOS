"""Check the first-stage ArcadeMacro bridge over the PC's Bluetooth adapter.

Requires: python -m pip install bleak
"""

import asyncio
from bleak import BleakClient, BleakScanner

SERVICE = "a8c70001-7d2b-4f4e-a5e9-8b7b5f66e001"
STATUS = "a8c70002-7d2b-4f4e-a5e9-8b7b5f66e001"
COMMAND = "a8c70003-7d2b-4f4e-a5e9-8b7b5f66e001"
RESPONSE = "a8c70004-7d2b-4f4e-a5e9-8b7b5f66e001"
INPUT = "a8c70005-7d2b-4f4e-a5e9-8b7b5f66e001"


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
        if INPUT not in [c.uuid for s in client.services for c in s.characteristics]:
            raise SystemExit("Stick input characteristic missing (old firmware?)")
        initial = await client.read_gatt_char(INPUT)
        print(f"Input (read): {initial.hex(' ').upper()}")
        updates = []
        await client.start_notify(INPUT, lambda _, data: updates.append(bytes(data)))
        print("Move the stick / press buttons for 10 seconds...")
        await asyncio.sleep(10)
        await client.stop_notify(INPUT)
        print(f"Input notifications received: {len(updates)}")
        for data in updates[:5]:
            print(f"  {data.hex(' ').upper()}")
        if not updates and "GAMEPAD_CONNECTED" in status:
            print("Warning: gamepad connected but no input notifications arrived")
    print("BLE bridge handshake passed")


if __name__ == "__main__":
    asyncio.run(main())
