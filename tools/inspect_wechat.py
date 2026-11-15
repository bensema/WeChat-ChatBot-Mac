#!/usr/bin/env python3
"""Inspect the installed Mach-O slice and verify the x86_64 Hook identity (read-only)."""
import argparse
import json
import mmap
import plistlib
import re
import struct
import subprocess
from pathlib import Path


def inspect_image(path, arch):
    cpu = {"x86_64": 0x01000007, "arm64": 0x0100000C}[arch]
    with path.open("rb") as source, mmap.mmap(source.fileno(), 0, access=mmap.ACCESS_READ) as image:
        origin = 0
        if image[:4] == b"\xca\xfe\xba\xbe":
            count = struct.unpack_from(">I", image, 4)[0]
            for index in range(count):
                cputype, _, offset, _, _ = struct.unpack_from(">IIIII", image, 8 + index * 20)
                if cputype == cpu:
                    origin = offset
                    break
            else:
                raise ValueError(f"{arch} slice is absent")
        magic, actual_cpu = struct.unpack_from("<II", image, origin)
        if magic != 0xFEEDFACF or actual_cpu != cpu:
            raise ValueError("unexpected Mach-O architecture/magic")
        commands = struct.unpack_from("<I", image, origin + 16)[0]
        cursor = origin + 32
        segments, uuid = [], ""
        for _ in range(commands):
            command, size = struct.unpack_from("<II", image, cursor)
            if size < 8 or cursor + size > len(image):
                raise ValueError("invalid Mach-O load command")
            if command == 0x19:
                name = image[cursor + 8:cursor + 24].split(b"\0")[0].decode()
                va, length, fileoff, filesize = struct.unpack_from("<QQQQ", image, cursor + 24)
                segments.append(dict(name=name, vmaddr=hex(va), vmsize=hex(length),
                                     fileoff=fileoff, filesize=filesize))
            elif command == 0x1B:
                raw = image[cursor + 8:cursor + 24].hex().upper()
                uuid = "-".join([raw[:8], raw[8:12], raw[12:16], raw[16:20], raw[20:]])
            cursor += size
        result = dict(arch=arch, uuid=uuid, staticImageBase=segments[0]["vmaddr"], segments=segments)
        def bytes_at_rva(address, length):
            for segment in segments:
                va = int(segment["vmaddr"], 16)
                if va <= address and address + length <= va + segment["filesize"]:
                    offset = origin + segment["fileoff"] + address - va
                    return image[offset:offset + length]
            raise ValueError("RVA is outside file-backed segments")
        result["_finalizer_bytes"] = bytes_at_rva(0x52F14C0, 14).hex(" ") if arch == "x86_64" else ""
        return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, default=Path("/Applications/WeChat.app"))
    parser.add_argument("--arch", choices=["x86_64", "arm64"], default="x86_64")
    parser.add_argument("--pid", type=int, help="also resolve the current image base using vmmap")
    args = parser.parse_args()
    with (args.app / "Contents/Info.plist").open("rb") as source:
        info = plistlib.load(source)
    version = info.get("WeChatBundleVersion", info.get("CFBundleShortVersionString", ""))
    build = str(info.get("CFBundleVersion", ""))
    path = args.app / "Contents/Resources/wechat.dylib"
    result = inspect_image(path, args.arch)
    result.update(version=version, build=build, image=str(path))
    signature = result.pop("_finalizer_bytes")
    config = Path(__file__).resolve().parents[1] / "hook/versions/4_1_15_35_x86_64.json"
    expected = json.loads(config.read_text())
    result["hookIdentityMatches"] = (args.arch == "x86_64" and version == expected["version"]
        and build == expected["build"] and result["uuid"] == expected["moduleUUID"]
        and signature == expected["messageFinalizerSignature"])
    if args.pid:
        snapshot = subprocess.run(["/usr/bin/vmmap", str(args.pid)], capture_output=True, text=True, check=True).stdout
        for line in snapshot.splitlines():
            match = re.match(r"__TEXT\s+([0-9a-f]+)-[0-9a-f]+\s", line)
            if match and line.rstrip().endswith(str(path)):
                base = int(match[1], 16)
                result["runtime"] = dict(pid=args.pid, base=hex(base),
                    messageFinalizer=hex(base + int(expected["messageFinalizerAddr"], 16)))
                break
        if "runtime" not in result:
            raise ValueError("target process does not map the selected image")
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return 0 if result["hookIdentityMatches"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
