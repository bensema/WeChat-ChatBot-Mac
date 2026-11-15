#!/usr/bin/env python3
"""Exercise compiled App code against local fixtures, including on CLT without XCTest.

Builds the existing debug target, links its production objects into a small runner,
and sends requests only to a random loopback port. No user configuration or keys.
Use --serve-only to expose the fixture temporarily for manual UI validation.
"""
import argparse
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import subprocess
import shutil
import tempfile
import threading
import time

ROOT = Path(__file__).resolve().parents[1]
RECEIVED = []


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def reply(self, value, status=200):
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        try:
            self.wfile.write(json.dumps(value, ensure_ascii=False).encode())
        except (BrokenPipeError, ConnectionResetError):
            pass

    def do_GET(self):
        if self.path != "/voice_status":
            return self.reply({"error": "unknown path"}, 404)
        if self.headers.get("Authorization") != "Bearer test-only-token":
            return self.reply({"error": "unauthorized"}, 401)
        self.reply({"ok": True, "hook": {"ready": True, "sendSupported": True}})

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        if self.path in ["/send_private_msg", "/send_group_msg"]:
            if self.headers.get("Authorization") != "Bearer test-only-token":
                return self.reply({"error": "unauthorized"}, 401)
            # Fixture records only in memory and never forwards to WeChat.
            RECEIVED.append((self.path, body))
            return self.reply({"status": "ok"})
        responses = self.path == "/v1/responses"
        if self.path not in ["/v1/responses", "/v1/chat/completions"]:
            return self.reply({"error": {"message": "wrong endpoint"}}, 404)
        if responses:
            assert "messages" not in body and "max_tokens" not in body
            assert body["store"] is False
            messages = body["input"]
            question = messages[-1]["content"][0]["text"]
        else:
            messages = body["messages"]
            question = messages[-1]["content"]
        if body["model"] == "slow":
            time.sleep(2)
        text = "模拟回复 " + question
        response = {
            "model": body["model"], "status": "completed",
            "output": [{"type": "message", "content": [{"type": "output_text", "text": text}]}],
            "usage": {"input_tokens": 5, "output_tokens": 7, "total_tokens": 12},
        } if responses else {
            "model": body["model"],
            "choices": [{"message": {"content": text}, "finish_reason": "stop"}],
            "usage": {"prompt_tokens": 5, "completion_tokens": 7, "total_tokens": 12},
        }
        if not body.get("stream"):
            return self.reply(response)
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.end_headers()
        if responses:
            events = [{"type": "response.output_text.delta", "delta": text},
                      {"type": "response.completed", "response": response}]
            if body["model"] == "fail":
                events = [{"type": "response.failed", "response": {"error": {"message": "expected failure"}}}]
        else:
            events = [{"model": body["model"], "choices": [{"delta": {"content": text}}]},
                      {"choices": [{"delta": {}, "finish_reason": "stop"}], "usage": response["usage"]}]
        try:
            for event in events:
                self.wfile.write(("data: " + json.dumps(event, ensure_ascii=False) + "\n\n").encode())
                self.wfile.flush()
            self.wfile.write(b"data: [DONE]\n\n")
        except (BrokenPipeError, ConnectionResetError):
            pass


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--serve-only", action="store_true")
    args = parser.parse_args()
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    port = server.server_port
    threading.Thread(target=server.serve_forever, daemon=True).start()
    if args.serve_only:
        print(json.dumps({"port": port, "ai_base": f"http://127.0.0.1:{port}/v1", "token": "test-only-token"}), flush=True)
        try:
            threading.Event().wait()
        except KeyboardInterrupt:
            return
    try:
        subprocess.run(["swift", "build", "--package-path", "app", "--scratch-path", "app/.build-interaction-test"], cwd=ROOT, check=True)
        directory = Path(subprocess.check_output(["swift", "build", "--package-path", "app", "--scratch-path", "app/.build-interaction-test", "--show-bin-path"], cwd=ROOT, text=True).strip())
        objects = sorted((directory / "WeChatAI.build").glob("*.swift.o"))
        objects = [str(p) for p in objects if p.name != "WeChatBotApp.swift.o"]
        if not objects:
            raise RuntimeError("missing production object files")
        with tempfile.TemporaryDirectory(prefix="wechatai-interaction-test-") as temp:
            runner = Path(temp) / "contracts"
            # Snapshot objects/modules so an independent App packaging build cannot
            # change link inputs while swiftc is type-checking this runner.
            snapshot = Path(temp) / "objects"
            snapshot.mkdir()
            shutil.copytree(directory / "Modules", Path(temp) / "Modules")
            copied = []
            for obj in objects:
                target = snapshot / Path(obj).name
                shutil.copy2(obj, target)
                copied.append(str(target))
            result = subprocess.run(["swiftc", "-parse-as-library", "-I", str(Path(temp) / "Modules"),
                                     str(ROOT / "tools/tests/InteractionContracts.swift"), *copied,
                                     "-o", str(runner)])
            if result.returncode:
                raise SystemExit("interaction contract runner compilation failed")
            subprocess.run([str(runner), str(port)], timeout=30, check=True)
        assert len(RECEIVED) == 2, "expected two sends to local fixture only"
        assert RECEIVED[0][1]["user_id"] == "wxid_xxx"
        assert RECEIVED[1][1]["group_id"] == "test@chatroom"
        print("PASS: manual target and group payloads reached only the loopback fixture")
    finally:
        server.shutdown()


if __name__ == "__main__":
    main()
