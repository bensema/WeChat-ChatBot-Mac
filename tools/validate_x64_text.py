#!/usr/bin/env python3
"""Validate native x64 text construction/serialization without submitting messages.

Requires the Python frida package and an attachable, logged-in WeChat process.
"""
import argparse
import json
from pathlib import Path
import time

import frida


def varint(value):
    output = bytearray()
    while value > 127:
        output.append((value & 127) | 128)
        value >>= 7
    output.append(value)
    return bytes(output)


def number(field, value):
    return varint(field * 8) + varint(value)


def binary(field, value):
    return varint(field * 8 + 2) + varint(len(value)) + value


def text_proto(content, client_id):
    body = binary(1, binary(1, b"filehelper"))
    body += binary(2, content.encode("utf-8")) + number(3, 1)
    body += number(4, int(time.time())) + number(5, client_id)
    body += binary(6, b"<msgsource><alnode><fr>1</fr></alnode></msgsource>")
    return (number(1, 1) + binary(2, body)).hex()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pid", type=int, required=True)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    config = json.loads((root / "hook/versions/4_1_15_35_x86_64.json").read_text())
    source = (root / "hook/script-x86_64.js").read_text()
    for key, value in config.items():
        source = source.replace("{{." + key + "}}", str(value))
    session = frida.attach(args.pid)
    try:
        script = session.create_script(source)
        script.load()
        api = script.exports_sync
        if api.x64_init_native_helper(str(root / "bridge/libwechat-x64.dylib")) != "1":
            raise RuntimeError("native completion helper initialization failed")
        for name, content, client_id in [
            ("short", "hello", 1),
            ("utf8_long", "Intel 构造校验，无网络发送。" * 128, 0x7FFFFFFF),
        ]:
            if api.x64_validate_text(text_proto(content, client_id)) != "1":
                raise RuntimeError("native validation failed: " + name)
            print(json.dumps({"case": name, "native_roundtrip": True}))
        # Prove that the 34-bit legacy ID is rejected before service submission.
        try:
            api.x64_validate_text(text_proto("invalid client ID", 1 << 34))
        except frida.core.RPCException:
            print(json.dumps({"case": "legacy_34bit_id", "rejected": True}))
        else:
            raise RuntimeError("legacy 34-bit ID unexpectedly accepted")
        status = json.loads(api.x64_status())
        if status["submitted"] != 0:
            raise RuntimeError("validation submitted a network task")
        print(json.dumps({"ready": status["ready"], "send_supported": status["sendSupported"], "submitted": 0}))
    finally:
        session.detach()


if __name__ == "__main__":
    main()
