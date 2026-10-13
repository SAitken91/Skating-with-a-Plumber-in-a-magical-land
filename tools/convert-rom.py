"""Converts a Super Mario 64 (USA) ROM to the .z64 byte order coopdx expects.

Usage: python tools/convert-rom.py <your rom (.z64/.v64/.n64)> [output]
Default output: game/user/baserom.us.z64. Checks the SHA-1 of the result.
"""
import array, hashlib, os, sys

US_SHA1 = "9bef1128717f958171a4afac3ed78ee2bb4e86ce"

def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    data = open(sys.argv[1], "rb").read()
    head = data[:4]
    if head == b"\x80\x37\x12\x40":
        rom = data                                   # .z64, big endian
    elif head == b"\x37\x80\x40\x12":
        a = array.array("H", data); a.byteswap(); rom = a.tobytes()   # .v64, 16-bit swapped
    elif head == b"\x40\x12\x37\x80":
        a = array.array("I", data); a.byteswap(); rom = a.tobytes()   # .n64, 32-bit little endian
    else:
        sys.exit("Not an N64 ROM (unknown header).")
    digest = hashlib.sha1(rom).hexdigest()
    if digest != US_SHA1:
        sys.exit(f"SHA-1 {digest} is not Super Mario 64 (USA); coopdx needs the US ROM.")
    here = os.path.dirname(os.path.abspath(__file__))
    out = sys.argv[2] if len(sys.argv) > 2 else os.path.join(here, "..", "game", "user", "baserom.us.z64")
    os.makedirs(os.path.dirname(os.path.abspath(out)), exist_ok=True)
    open(out, "wb").write(rom)
    print("Wrote", os.path.abspath(out))

if __name__ == "__main__":
    main()
