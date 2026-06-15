"""WHOOP BLE packet codec — fully reverse-engineered framing.

Frame layout:
    0xAA | len(uint16 LE) | CRC8(len) | payload | CRC32(payload, LE)

  - len      = len(payload) + 4   (i.e. total_bytes - 4)
  - CRC8     = CRC-8 (poly 0x07, init 0x00) over the 2 length bytes
  - CRC32    = CRC-32/ISO-HDLC (zlib.crc32) over the payload bytes only

Verified against 11 captured frames from the device. This lets us both validate
incoming frames and BUILD valid outgoing command packets.
"""
import zlib

def crc8(data: bytes, poly=0x07, init=0x00) -> int:
    c = init
    for byte in data:
        c ^= byte
        for _ in range(8):
            c = ((c << 1) ^ poly) & 0xFF if (c & 0x80) else (c << 1) & 0xFF
    return c

def encode(payload: bytes) -> bytes:
    """Wrap a payload in a valid WHOOP frame the device will accept."""
    ln = len(payload) + 4
    length_bytes = ln.to_bytes(2, "little")
    frame = bytes([0xAA]) + length_bytes + bytes([crc8(length_bytes)])
    frame += payload
    frame += (zlib.crc32(payload) & 0xFFFFFFFF).to_bytes(4, "little")
    return frame

def decode(frame: bytes):
    """Return (payload, ok). ok=False if any check fails."""
    if len(frame) < 8 or frame[0] != 0xAA:
        return b"", False
    length_bytes = frame[1:3]
    ln = length_bytes[0] | (length_bytes[1] << 8)
    if frame[3] != crc8(length_bytes):
        return b"", False
    payload = frame[4:ln]
    given = int.from_bytes(frame[ln:ln+4], "little")
    if (zlib.crc32(payload) & 0xFFFFFFFF) != given:
        return b"", False
    return payload, True


if __name__ == "__main__":
    frames = [
        "aa1400033085660009c9296a003b040001010000b1317fa1",
        "aa140003308666000bc9296a001b040001010000cbfc8493",
        "aa10005730a3160015c9296a582c0000419bc28c",
        "aa3000f930a520001bc9296ad01d20000301153f250001350506001f00000000000000000000cb090400000028ebb33ed811ae5e",
        "aa2400fa305f0300ffc8296a88251400025c010000fa0e00000101070d0100240100000059072b54",
    ]
    ok_count = 0
    for h in frames:
        raw = bytes.fromhex(h)
        payload, ok = decode(raw)
        # round-trip: re-encoding the payload must reproduce the exact frame
        roundtrip = encode(payload) == raw
        ok_count += ok and roundtrip
        print(f"{'OK ' if ok and roundtrip else 'BAD'}  len={len(raw):3}  payload[{len(payload)}]={payload.hex()}")
    print(f"\n{ok_count}/{len(frames)} frames verified + round-tripped")
