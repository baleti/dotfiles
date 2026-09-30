#!/usr/bin/env python3
"""
Regression check for the Peer App Debugger privileged-relay pipeline
(~/src/peeragent-android, ~/src/peer-app-debugger-android). Formalizes the
security/functional checks that were verified by hand, live, while building
this feature - so a future code change gets checked against the same things
instead of relying on remembering to retest manually.

Two tiers, run in this order deliberately:
  1. Crypto/protocol checks - only need peeragent itself reachable (a
     persistent foreground service, essentially always up). Fast, and
     always meaningful regardless of whether the privileged helper happens
     to be armed right now.
  2. Live-helper checks - need the privileged helper actually bootstrapped
     and polling, which is its exception, not its resting state (it's
     meant to be started on demand, not left running). These can take up
     to ~65s each when the helper is offline, and are reported as SKIP
     (not FAIL) in that case rather than a confusing failure that looks
     like a real regression.

Needs the phone reachable over WireGuard and host3's Ed25519 private key
(~/.config/peer-app-debugger/host3-ed25519-private.pem).

Usage: peer-app-debugger-regression-check.py
Exit code: 0 if every tier-1 check passes and no tier-2 check FAILs (SKIPs
are fine); 1 if any check outright fails.
"""
import base64
import hashlib
import importlib.util
import secrets
import sys
import time

import requests

spec = importlib.util.spec_from_file_location(
    "peer_app_debugger_request", "/home/user1/bin/peer-app-debugger-request.py",
)
padr = importlib.util.module_from_spec(spec)
spec.loader.exec_module(padr)

PHONE_HOST = padr.PHONE_HOST
PHONE_PORT = padr.PHONE_PORT
BASE = f"http://{PHONE_HOST}:{PHONE_PORT}"
HELPER_OFFLINE_MARKERS = ("timed out waiting for helper", "already in flight")

results = []  # (name, status in {PASS, FAIL, SKIP}, detail)


def check(name):
    def decorator(fn):
        def wrapper(*args, **kwargs):
            try:
                status, detail = fn(*args, **kwargs)
            except Exception as e:
                status, detail = "FAIL", f"exception: {e.__class__.__name__}: {e}"
            results.append((name, status, detail))
            print(f"{status:4}  {name}  -  {detail}")
            return status
        return wrapper
    return decorator


def sign_stale(path_and_query: str, age_ms: int) -> dict:
    key = padr.load_key()
    ts = str(int(time.time() * 1000) - age_ms)
    nonce = secrets.token_hex(16)
    body_hash = base64.b64encode(hashlib.sha256(b"").digest()).decode()
    canonical = f"GET\n{path_and_query}\n{ts}\n{nonce}\n{body_hash}"
    sig = base64.b64encode(key.sign(canonical.encode())).decode()
    return {"X-Peer-Agent": "1", "X-Timestamp": ts, "X-Nonce": nonce, "X-Signature": sig}


# ---------- Tier 1: crypto/protocol, peeragent-only ----------

@check("baseline: peeragent /status reachable")
def test_baseline():
    r = requests.get(f"{BASE}/status", headers={"X-Peer-Agent": "1"}, timeout=10)
    return ("PASS" if r.status_code == 200 else "FAIL"), f"HTTP {r.status_code}"


@check("forged signature is rejected")
def test_bad_signature_rejected():
    path_and_query = "/privileged/diagnostics?pkg=dev.local.peeragent"
    headers = padr.sign_request("GET", path_and_query, b"")
    headers["X-Signature"] = base64.b64encode(b"A" * 64).decode()
    r = requests.get(f"{BASE}{path_and_query}", headers=headers, timeout=10)
    ok = r.status_code == 401 and "signature" in r.text.lower()
    return ("PASS" if ok else "FAIL"), f"HTTP {r.status_code}: {r.text}"


@check("missing signature headers rejected")
def test_missing_signature_rejected():
    r = requests.get(
        f"{BASE}/privileged/diagnostics?pkg=dev.local.peeragent",
        headers={"X-Peer-Agent": "1"}, timeout=10,
    )
    ok = r.status_code == 401 and "missing" in r.text.lower()
    return ("PASS" if ok else "FAIL"), f"HTTP {r.status_code}: {r.text}"


@check("query-string tampering invalidates the signature")
def test_query_tampering_rejected():
    # Sign a request for peeragent's own package, then send it with the
    # query swapped to a different (still-allowlisted) package. Regression
    # test for the fix where the signature didn't originally cover the
    # query string at all - this exact swap used to pass.
    path_and_query = "/privileged/diagnostics?pkg=dev.local.peeragent"
    headers = padr.sign_request("GET", path_and_query, b"")
    tampered = "/privileged/diagnostics?pkg=dev.local.dictate"
    r = requests.get(f"{BASE}{tampered}", headers=headers, timeout=10)
    ok = r.status_code == 401 and "signature" in r.text.lower()
    return ("PASS" if ok else "FAIL"), f"HTTP {r.status_code}: {r.text}"


@check("stale timestamp (outside skew window) is rejected")
def test_timestamp_skew_rejected():
    path_and_query = "/privileged/diagnostics?pkg=dev.local.peeragent"
    headers = sign_stale(path_and_query, age_ms=10 * 60_000)  # 10 minutes ago
    r = requests.get(f"{BASE}{path_and_query}", headers=headers, timeout=10)
    ok = r.status_code == 401 and "skew" in r.text.lower()
    return ("PASS" if ok else "FAIL"), f"HTTP {r.status_code}: {r.text}"


# ---------- Tier 2: needs the privileged helper actually running ----------

_last_valid_headers = None
_last_valid_path = None


@check("valid signed diagnostics succeeds (needs helper armed)")
def test_valid_diag():
    # Timeout exceeds HelperBridge.WAIT_TIMEOUT_MS (60s) deliberately - a
    # shorter one here would time out client-side before peeragent itself
    # gives up waiting on the helper, which looks identical to a real
    # failure but isn't testing what it claims to.
    path_and_query = "/privileged/diagnostics?pkg=dev.local.peeragent"
    headers = padr.sign_request("GET", path_and_query, b"")
    global _last_valid_headers, _last_valid_path
    try:
        r = requests.get(f"{BASE}{path_and_query}", headers=headers, timeout=65)
    except requests.exceptions.Timeout:
        return "SKIP", "client-side timeout - helper likely not armed"
    if any(m in r.text for m in HELPER_OFFLINE_MARKERS):
        return "SKIP", f"helper not armed/polling right now - HTTP {r.status_code}: {r.text}"
    if r.status_code == 200 and "versionCode" in r.text:
        _last_valid_headers, _last_valid_path = headers, path_and_query
        return "PASS", f"HTTP {r.status_code}: {r.text[:120]}"
    return "FAIL", f"HTTP {r.status_code}: {r.text}"


@check("exact replay of a valid signed request is rejected")
def test_replay_rejected():
    if _last_valid_path is None:
        return "SKIP", "no valid request from the previous check to replay"
    r = requests.get(f"{BASE}{_last_valid_path}", headers=_last_valid_headers, timeout=10)
    ok = r.status_code == 401 and "replay" in r.text.lower()
    return ("PASS" if ok else "FAIL"), f"HTTP {r.status_code}: {r.text}"


@check("non-allowlisted package is rejected (needs helper armed)")
def test_non_allowlisted_rejected():
    path_and_query = "/privileged/diagnostics?pkg=com.android.settings"
    headers = padr.sign_request("GET", path_and_query, b"")
    try:
        r = requests.get(f"{BASE}{path_and_query}", headers=headers, timeout=65)
    except requests.exceptions.Timeout:
        return "SKIP", "client-side timeout - helper likely not armed"
    if any(m in r.text for m in HELPER_OFFLINE_MARKERS):
        return "SKIP", f"helper not armed/polling right now - HTTP {r.status_code}: {r.text}"
    ok = "not allowed" in r.text.lower()
    return ("PASS" if ok else "FAIL"), f"HTTP {r.status_code}: {r.text}"


if __name__ == "__main__":
    print(f"Peer App Debugger regression check - {time.strftime('%Y-%m-%d %H:%M:%S')}")
    print(f"Target: {BASE}\n")

    print("--- Tier 1: crypto/protocol (peeragent only) ---")
    test_baseline()
    test_bad_signature_rejected()
    test_missing_signature_rejected()
    test_query_tampering_rejected()
    test_timestamp_skew_rejected()

    print("\n--- Tier 2: live helper (may SKIP if not currently armed) ---")
    test_valid_diag()
    test_replay_rejected()
    test_non_allowlisted_rejected()

    print()
    passed = sum(1 for _, s, _ in results if s == "PASS")
    skipped = sum(1 for _, s, _ in results if s == "SKIP")
    failed = [r for r in results if r[1] == "FAIL"]
    total = len(results)
    print(f"{passed}/{total} passed, {skipped} skipped, {len(failed)} failed")
    if failed:
        print("\nFAILED:")
        for name, _, detail in failed:
            print(f"  - {name}: {detail}")
        sys.exit(1)
    sys.exit(0)
