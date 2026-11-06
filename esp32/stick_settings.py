"""Read (and optionally change macros in) the 8BitDo Arcade Stick 80FE settings
through the ArcadeMacro bridge v3, using the PC's Bluetooth adapter.

    python stick_settings.py                 # read and decode, changes nothing
    python stick_settings.py --save out.bin  # also save the raw 564-byte block
    python stick_settings.py --test-macro    # write a demo macro (P1: A,B,A) to slot 1
    python stick_settings.py --clear-macros  # remove all macros from the active profile

Requires: python -m pip install bleak
"""

import argparse
import asyncio
import struct

from bleak import BleakClient, BleakScanner

COMMAND = "a8c70003-7d2b-4f4e-a5e9-8b7b5f66e001"
RESPONSE = "a8c70004-7d2b-4f4e-a5e9-8b7b5f66e001"
STATUS = "a8c70002-7d2b-4f4e-a5e9-8b7b5f66e001"
DATA = "a8c70006-7d2b-4f4e-a5e9-8b7b5f66e001"

BLOCK = 564
SLOT_BASE, SLOT_SIZE, MACRO_OFF = 4, 280, 36
FLAG = 0x20191212

# Bit values from the official software (BasicAdvanceUIData, Arcade Stick variant).
BUTTONS = {
    "A": 0x2000, "B": 0x1000, "X": 0x10, "Y": 0x20, "L1": 0x400, "R1": 0x800,
    "L2": 0x4000, "R2": 0x8000, "L3": 0x2, "R3": 0x4, "SELECT": 0x8, "START": 0x1,
    "HOME": 0x20000, "STAR": 0x10000, "UP": 0x200, "DOWN": 0x100, "LEFT": 0x80,
    "RIGHT": 0x40, "P1": 0x2000000, "P2": 0x4000000,
}


def names(mask):
    found = [n for n, b in BUTTONS.items() if mask & b]
    return "+".join(found) if found else ("none" if mask == 0 else hex(mask))


def decode(block):
    crc, ver, platform = struct.unpack_from("<HBB", block, 0)
    print(f"struct_ver={ver} platform={platform} ({'Switch/S' if platform == 0 else 'Windows/X'})")
    for s in range(2):
        base = SLOT_BASE + s * SLOT_SIZE
        flag = struct.unpack_from("<I", block, base)[0]
        name = block[base + 4:base + 36].decode("utf-16-le", "replace").rstrip("\0")
        mbase = base + MACRO_OFF
        mflag, count = struct.unpack_from("<IB", block, mbase)
        print(f"slot {s}{' (active)' if s == min(platform, 1) else ''}: flag={flag:#x} "
              f"name={name!r} macro_flag={mflag:#x} macros={count}")
        for k in range(2):
            r = mbase + 8 + k * 80
            trigger = struct.unpack_from("<I", block, r)[0]
            times = struct.unpack_from("<18H", block, r + 4)
            keys = struct.unpack_from("<18H", block, r + 40)
            steps = block[r + 76]
            if trigger == 0 and steps == 0:
                continue
            seq = ", ".join(f"{names(keys[i])} {times[i]}ms" for i in range(min(steps, 18)))
            print(f"  macro {k + 1}: trigger={names(trigger)} steps={steps}: {seq}")
        mapb = base + 204
        keys = struct.unpack_from("<18I", block, mapb + 4)
        print(f"  mapping flag={struct.unpack_from('<I', block, mapb)[0]:#x} keys={[hex(k) for k in keys]}")


def set_macros(block, macros):
    """macros: list of (trigger_mask, [(button_mask, ms), ...]), at most 2."""
    b = bytearray(block)
    slot = min(b[3], 1)
    mbase = SLOT_BASE + slot * SLOT_SIZE + MACRO_OFF
    b[mbase:mbase + 168] = bytes(168)
    struct.pack_into("<IB", b, mbase, FLAG, len(macros))
    for k, (trigger, steps) in enumerate(macros):
        r = mbase + 8 + k * 80
        times = [51] * 18
        keys = [0] * 18
        for i, (mask, ms) in enumerate(steps[:18]):
            keys[i], times[i] = mask, ms
        struct.pack_into("<I18H18HB", b, r, trigger, *times, *keys, min(len(steps), 18))
    return bytes(b)


async def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--save")
    ap.add_argument("--test-macro", action="store_true")
    ap.add_argument("--clear-macros", action="store_true")
    args = ap.parse_args()

    print("Scanning for ArcadeMacro Bridge...")
    dev = await BleakScanner.find_device_by_name("ArcadeMacro Bridge", timeout=15)
    if dev is None:
        raise SystemExit("Bridge not found (is the phone still connected to it?)")
    async with BleakClient(dev) as client:
        block = bytearray(BLOCK)
        replies = asyncio.Queue()

        def on_data(_, d):
            off = d[0] | d[1] << 8
            block[off:off + len(d) - 2] = d[2:]

        await client.start_notify(DATA, on_data)
        await client.start_notify(RESPONSE, lambda _, d: replies.put_nowait(d.decode()))
        print("Status:", (await client.read_gatt_char(STATUS)).decode())

        async def command(text, timeout=30):
            await client.write_gatt_char(COMMAND, text.encode(), response=True)
            reply = await asyncio.wait_for(replies.get(), timeout)
            print(f"{text} -> {reply}")
            return reply

        if not (await command("READ")).startswith("READ OK"):
            raise SystemExit(1)
        await asyncio.sleep(0.3)
        decode(bytes(block))
        if args.save:
            open(args.save, "wb").write(block)
            print("saved", args.save)

        new = None
        if args.test_macro:
            new = set_macros(block, [(BUTTONS["P1"], [(BUTTONS["A"], 100), (0, 100),
                                                       (BUTTONS["B"], 100), (0, 100),
                                                       (BUTTONS["A"], 100)])])
        elif args.clear_macros:
            new = set_macros(block, [])
        if new is not None:
            for off in range(0, BLOCK, 16):
                await client.write_gatt_char(DATA, bytes([off & 0xFF, off >> 8]) + new[off:off + 16], response=True)
            if (await command("WRITE")).startswith("WRITE OK"):
                await command("READ")
                await asyncio.sleep(0.3)
                print("--- after write")
                decode(bytes(block))


if __name__ == "__main__":
    asyncio.run(main())
