#!/usr/bin/env python3
"""Check that an asc-mcp binary can sign an App Store Connect JWT locally.

Starts the server over stdio with a throwaway P-256 key, calls `auth_generate_token`
and requires it to succeed (the token itself is never returned). Nothing is sent to Apple.
"""

import json
import os
import subprocess
import sys
import tempfile


def main() -> int:
    binary = sys.argv[1]
    with tempfile.TemporaryDirectory() as tmp:
        key_path = os.path.join(tmp, "key.p8")
        subprocess.run(
            "openssl ecparam -name prime256v1 -genkey -noout | openssl pkcs8 -topk8 -nocrypt",
            shell=True, check=True, stdout=open(key_path, "wb"),
        )
        env = {
            **os.environ,
            "ASC_KEY_ID": "PROBE12345",
            "ASC_ISSUER_ID": "00000000-0000-0000-0000-000000000000",
            "ASC_PRIVATE_KEY": open(key_path).read(),
            "HOME": tmp,
        }
        messages = [
            {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
                "protocolVersion": "2025-06-18", "capabilities": {},
                "clientInfo": {"name": "jwt-probe", "version": "1"}}},
            {"jsonrpc": "2.0", "method": "notifications/initialized"},
            {"jsonrpc": "2.0", "id": 2, "method": "tools/call",
             "params": {"name": "auth_generate_token", "arguments": {}}},
        ]
        stdin = "".join(json.dumps(m) + "\n" for m in messages)
        proc = subprocess.Popen([binary], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE, env=env)
        response = None
        try:
            proc.stdin.write(stdin.encode())
            proc.stdin.flush()
            for raw in proc.stdout:
                payload = json.loads(raw)
                if payload.get("id") == 2:
                    response = payload
                    break
        finally:
            proc.kill()
            stderr = proc.stderr.read().decode(errors="replace")

    if response is None:
        print(f"no tools/call response; exit={proc.wait()} stderr:\n{stderr[-3000:]}", file=sys.stderr)
        return 1
    result = response.get("result") or {}
    text = "".join(c.get("text", "") for c in result.get("content", []))
    # The tool never returns the token itself; success means signing completed in-process.
    if result.get("isError") or "generated successfully" not in text:
        print(f"token generation failed: {json.dumps(response)[:2000]}", file=sys.stderr)
        return 1
    print("auth_generate_token signed a JWT successfully")
    return 0


if __name__ == "__main__":
    sys.exit(main())
