#!/usr/bin/env python3
"""Minimal Chrome DevTools Protocol driver, real input events only
(mouse clicks at coordinates, real keystrokes) so it works against any
web app regardless of framework - no direct DOM/.value manipulation,
which Angular apps like Cloud Console ignore.

Usage: cdp.py <command> [args...]
  new <url>                    -> print page id
  nav <page_id> <url>
  shot <page_id> <out.png>
  click <page_id> <x> <y>
  type <page_id> <text>
  key <page_id> <key_name>     (Enter, Tab, Escape, etc.)
  eval <page_id> <js>          -> print result (read-only introspection only)
  pages                        -> list open pages
"""
import sys, json, base64, time
import websocket

CDP_HTTP = "http://127.0.0.1:9222"

def http(path):
    import urllib.request
    with urllib.request.urlopen(CDP_HTTP + path) as r:
        return json.loads(r.read())

def ws_connect(page_id):
    pages = http("/json/list")
    target = next(p for p in pages if p["id"] == page_id)
    ws = websocket.create_connection(target["webSocketDebuggerUrl"], timeout=15)
    return ws

def send(ws, method, params=None, msg_id=1):
    ws.send(json.dumps({"id": msg_id, "method": method, "params": params or {}}))
    while True:
        resp = json.loads(ws.recv())
        if resp.get("id") == msg_id:
            return resp

def main():
    cmd = sys.argv[1]
    if cmd == "pages":
        for p in http("/json/list"):
            if p["type"] == "page":
                print(p["id"], p["url"], "|", p.get("title", ""))
        return
    if cmd == "new":
        import urllib.request
        req = urllib.request.Request(f"{CDP_HTTP}/json/new?{sys.argv[2]}", method="PUT")
        with urllib.request.urlopen(req) as resp:
            d = json.loads(resp.read())
        print(d["id"])
        return

    page_id = sys.argv[2]
    ws = ws_connect(page_id)
    send(ws, "Page.enable", msg_id=100)
    send(ws, "DOM.enable", msg_id=101)
    send(ws, "Runtime.enable", msg_id=102)

    if cmd == "nav":
        send(ws, "Page.navigate", {"url": sys.argv[3]}, msg_id=1)
        time.sleep(2.5)
        print("ok")
    elif cmd == "shot":
        r = send(ws, "Page.captureScreenshot", {"format": "png"}, msg_id=1)
        data = base64.b64decode(r["result"]["data"])
        with open(sys.argv[3], "wb") as f:
            f.write(data)
        print("saved", sys.argv[3])
    elif cmd == "click":
        x, y = float(sys.argv[3]), float(sys.argv[4])
        send(ws, "Input.dispatchMouseEvent",
             {"type": "mouseMoved", "x": x, "y": y, "buttons": 0}, msg_id=1)
        send(ws, "Input.dispatchMouseEvent",
             {"type": "mousePressed", "x": x, "y": y, "button": "left", "buttons": 1, "clickCount": 1}, msg_id=2)
        time.sleep(0.05)
        send(ws, "Input.dispatchMouseEvent",
             {"type": "mouseReleased", "x": x, "y": y, "button": "left", "buttons": 0, "clickCount": 1}, msg_id=3)
        print("ok")
    elif cmd == "type":
        text = sys.argv[3]
        for i, ch in enumerate(text):
            send(ws, "Input.dispatchKeyEvent", {"type": "keyDown", "text": ch}, msg_id=1000 + i * 2)
            send(ws, "Input.dispatchKeyEvent", {"type": "keyUp", "text": ch}, msg_id=1001 + i * 2)
        print("ok")
    elif cmd == "key":
        keymap = {
            "Enter": {"key": "Enter", "code": "Enter", "windowsVirtualKeyCode": 13},
            "Tab": {"key": "Tab", "code": "Tab", "windowsVirtualKeyCode": 9},
            "Escape": {"key": "Escape", "code": "Escape", "windowsVirtualKeyCode": 27},
            "Backspace": {"key": "Backspace", "code": "Backspace", "windowsVirtualKeyCode": 8},
        }
        kd = keymap[sys.argv[3]]
        send(ws, "Input.dispatchKeyEvent", {"type": "keyDown", **kd}, msg_id=1)
        send(ws, "Input.dispatchKeyEvent", {"type": "keyUp", **kd}, msg_id=2)
        print("ok")
    elif cmd == "jsclick":
        # Fallback for pages where synthetic Input.dispatchMouseEvent
        # doesn't register (seen on some Google accounts.google.com
        # consent pages) - dispatches a real .click() on the first
        # button/element whose trimmed text matches exactly.
        text = sys.argv[3]
        js = (
            "(function(){const t=" + json.dumps(text) + ";"
            "const els=[...document.querySelectorAll('button,div[role=button],span,a')]"
            ".filter(e=>e.textContent.trim()===t);"
            "if(els.length){els[0].click();return 'clicked'} return 'not found'})()"
        )
        r = send(ws, "Runtime.evaluate", {"expression": js, "returnByValue": True}, msg_id=1)
        print(r.get("result", {}).get("result", {}).get("value"))
    elif cmd == "eval":
        r = send(ws, "Runtime.evaluate", {"expression": sys.argv[3], "returnByValue": True}, msg_id=1)
        print(json.dumps(r.get("result", {}).get("result", {}).get("value")))
    ws.close()

if __name__ == "__main__":
    main()
