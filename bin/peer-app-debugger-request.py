#!/usr/bin/env python3
"""
Signs and sends a request to peeragent's privileged-relay endpoints
(/privileged/diagnostics, /privileged/install), which forward to the
"Peer App Debugger" helper on the phone. See ~/src/peer-app-debugger-android
and the plan at ~/.claude/plans/lovely-strolling-owl.md.

Usage:
  peer-app-debugger-request.py diag <package>
  peer-app-debugger-request.py logcat <package>
  peer-app-debugger-request.py screenshot <output-path.png>
  peer-app-debugger-request.py install <package> <path-to-apk>

The private key never leaves this file/host - only a signature over the
request is sent. Matching public key is hardcoded into peeragent's
Ed25519Verify.kt.
"""
import base64
import hashlib
import os
import secrets
import sys
import time
import urllib.parse

import requests
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives.serialization import load_pem_private_key

PRIVATE_KEY_PATH = os.path.expanduser("~/.config/peer-app-debugger/host3-ed25519-private.pem")
PHONE_HOST = "10.10.0.5"
PHONE_PORT = 8788


def load_key() -> Ed25519PrivateKey:
    with open(PRIVATE_KEY_PATH, "rb") as f:
        return load_pem_private_key(f.read(), password=None)


def sign_request(method: str, path_and_query: str, body: bytes) -> dict:
    # path_and_query must be EXACTLY the string appended to the request line
    # on the wire (peeragent's Ed25519Verify covers it, including the query
    # string - which pkg= is - not just the bare path). Built and sent as
    # one literal string here, rather than via requests' own params=, so
    # there's no risk of the two ever drifting apart (different percent-
    # encoding, key ordering, etc).
    key = load_key()
    timestamp_ms = int(time.time() * 1000)
    nonce = secrets.token_hex(16)
    body_hash = base64.b64encode(hashlib.sha256(body).digest()).decode()
    canonical = f"{method}\n{path_and_query}\n{timestamp_ms}\n{nonce}\n{body_hash}"
    signature = base64.b64encode(key.sign(canonical.encode("utf-8"))).decode()
    return {
        "X-Peer-Agent": "1",
        "X-Timestamp": str(timestamp_ms),
        "X-Nonce": nonce,
        "X-Signature": signature,
    }


def diag(pkg: str):
    # Timeout must exceed peeragent's HelperBridge.WAIT_TIMEOUT_MS (60s) -
    # a shorter one here times out client-side before peeragent itself ever
    # gives up waiting on the helper, which looks identical to a real
    # failure but isn't testing what it claims to (bit twice before this
    # was fixed).
    path_and_query = "/privileged/diagnostics?" + urllib.parse.urlencode({"pkg": pkg})
    headers = sign_request("GET", path_and_query, b"")
    try:
        r = requests.get(f"http://{PHONE_HOST}:{PHONE_PORT}{path_and_query}", headers=headers, timeout=65)
        print(r.status_code, r.text)
    except requests.exceptions.Timeout:
        print("(client-side timeout after 65s - peeragent itself should have responded by now; check connectivity)")


def logcat(pkg: str):
    path_and_query = "/privileged/diagnostics?" + urllib.parse.urlencode({"pkg": pkg, "action": "LOGCAT"})
    headers = sign_request("GET", path_and_query, b"")
    try:
        r = requests.get(f"http://{PHONE_HOST}:{PHONE_PORT}{path_and_query}", headers=headers, timeout=65)
        print(r.status_code, r.text)
    except requests.exceptions.Timeout:
        print("(client-side timeout after 65s - peeragent itself should have responded by now; check connectivity)")


def screenshot(output_path: str):
    path_and_query = "/privileged/screenshot"
    headers = sign_request("GET", path_and_query, b"")
    try:
        r = requests.get(f"http://{PHONE_HOST}:{PHONE_PORT}{path_and_query}", headers=headers, timeout=65)
    except requests.exceptions.Timeout:
        print("(client-side timeout after 65s - peeragent itself should have responded by now; check connectivity)")
        return
    if r.status_code != 200:
        print(r.status_code, r.text)
        return
    with open(output_path, "wb") as f:
        f.write(r.content)
    print(f"saved {len(r.content)} bytes to {output_path}")


def install(pkg: str, apk_path: str):
    # Fire-and-forget: installing peeragent's own package kills and restarts
    # its process partway through pm install, tearing down the very HTTP
    # response that would carry a synchronous result. Confirm via diag.
    path_and_query = "/privileged/install?" + urllib.parse.urlencode({"pkg": pkg})
    with open(apk_path, "rb") as f:
        body = f.read()
    headers = sign_request("POST", path_and_query, body)
    headers["Content-Type"] = "application/vnd.android.package-archive"
    try:
        r = requests.post(f"http://{PHONE_HOST}:{PHONE_PORT}{path_and_query}", data=body, headers=headers, timeout=15)
        print(r.status_code, r.text)
    except requests.exceptions.RequestException as e:
        print(f"(request-side error, install may still have gone through - confirm via diag): {e}")
    print("waiting 5s, then confirming via diag...")
    time.sleep(5)
    diag(pkg)


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)
    cmd = sys.argv[1]
    if cmd == "diag" and len(sys.argv) == 3:
        diag(sys.argv[2])
    elif cmd == "logcat" and len(sys.argv) == 3:
        logcat(sys.argv[2])
    elif cmd == "screenshot" and len(sys.argv) == 3:
        screenshot(sys.argv[2])
    elif cmd == "install" and len(sys.argv) == 4:
        install(sys.argv[2], sys.argv[3])
    else:
        print(__doc__)
        sys.exit(1)
