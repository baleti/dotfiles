#!/usr/bin/env python3
"""PipeWire graph snapshot for the bar's volume panel: prints one JSON object.

Combines `pw-dump` (nodes, ports, links, metadata) with `pw-top -b` (live
per-node quantum/wait/busy/xruns) and lays the audio graph out left to right
(sources -> filters -> sinks) so the QML side only has to draw rectangles and
curves. All geometry is in "world" units; the viewer pans/zooms them.
"""
import json
import re
import subprocess
import sys

NODE_W = 210
HEAD_H = 26
PORT_H = 16
COL_GAP = 90
ROW_GAP = 16
PAD = 20


def run(cmd, timeout=3):
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout).stdout
    except Exception:
        return ""


def pw_top():
    """Last sample of `pw-top -b -n 2` -> {node id: stats}."""
    out = run(["pw-top", "-b", "-n", "2"])
    blocks = out.split("S   ID  QUANT")
    if len(blocks) < 2:
        return {}
    stats = {}
    for line in blocks[-1].splitlines()[1:]:
        t = line.split()
        if len(t) < 9 or not t[1].isdigit():
            continue
        fmt = re.match(r"(\S+)\s+(\d+)\s+(\d+)", " ".join(t[9:]))

        def num(s):
            try:
                return float(s.rstrip("usmn"))
            except ValueError:
                return None

        def us(s):
            m = re.match(r"([\d.]+)(us|ms|s|ns)", s)
            if not m:
                return None
            return float(m.group(1)) * {"ns": 0.001, "us": 1, "ms": 1000, "s": 1e6}[m.group(2)]

        stats[int(t[1])] = {
            "quantum": int(t[2]), "rate": int(t[3]),
            "waitUs": us(t[4]), "busyUs": us(t[5]),
            "wq": num(t[6]) if t[6] != "???" and t[6] != "---" else None,
            "bq": num(t[7]) if t[7] != "???" and t[7] != "---" else None,
            "errors": int(t[8]) if t[8].isdigit() else 0,
            "format": (fmt.group(0) if fmt else "") if len(t) > 9 else "",
        }
    return stats


def kind_of(props):
    cls = props.get("media.class", "")
    if props.get("bluez5.loopback") == "true" or props.get("node.link-group"):
        if cls.startswith("Audio/Source") or "Internal" in cls:
            return "filter"
    if cls == "Audio/Sink":
        return "sink"
    if cls.startswith("Audio/Source"):
        return "source"
    if cls == "Stream/Output/Audio":
        return "playback"
    if cls == "Stream/Input/Audio":
        return "capture"
    if cls.startswith("Audio/") or "Audio" in cls:
        return "filter"
    return "other"


def flat_props(props):
    out = {}
    for k, v in props.items():
        if isinstance(v, (dict, list)):
            v = json.dumps(v)
        s = str(v)
        out[k] = s if len(s) <= 160 else s[:157] + "..."
    return out


def main():
    dump = json.loads(run(["pw-dump"]) or "[]")
    top = pw_top()

    nodes, ports, links = {}, {}, []
    meta = {}
    n_clients = n_devices = 0
    for o in dump:
        t = o["type"].split(":")[-1]
        info = o.get("info") or {}
        if t == "Node":
            nodes[o["id"]] = o
        elif t == "Port":
            ports[o["id"]] = o
        elif t == "Link":
            links.append(o)
        elif t == "Client":
            n_clients += 1
        elif t == "Device":
            n_devices += 1
        elif t == "Metadata":
            name = (o.get("props") or {}).get("metadata.name")
            meta[name] = {m["key"]: m["value"] for m in o.get("metadata", []) if m.get("subject") == 0}

    settings = meta.get("settings", {})
    defaults = meta.get("default", {})
    sm = meta.get("sm-settings", {})

    # ---- which nodes belong in the audio graph ---------------------------
    linked = set()
    for l in links:
        i = l["info"]
        linked.add(i["output-node-id"])
        linked.add(i["input-node-id"])

    shown = {}
    for nid, o in nodes.items():
        props = o["info"]["props"]
        cls = props.get("media.class", "")
        if cls.startswith("Video") or cls.startswith("Midi") or "Midi" in cls:
            continue
        if not cls and nid not in linked:
            continue   # dummy/freewheel drivers, midi bridge
        if not (cls.startswith("Audio") or "Audio" in cls or nid in linked):
            continue
        shown[nid] = o

    # ---- ports per node --------------------------------------------------
    node_ports = {nid: {"in": [], "out": []} for nid in shown}
    for pid, p in ports.items():
        pr = p["info"]["props"]
        nid = pr.get("node.id")
        if nid in shown:
            d = "in" if pr.get("port.direction") == "in" else "out"
            node_ports[nid][d].append((pr.get("port.id", pid), pid, pr))
    for nid in node_ports:
        for d in ("in", "out"):
            node_ports[nid][d].sort(key=lambda x: x[0])

    # ---- layering: longest path from sources ------------------------------
    edges = []
    for l in links:
        i = l["info"]
        a, b = i["output-node-id"], i["input-node-id"]
        if a in shown and b in shown and a != b:
            edges.append((a, b))
    rank = {nid: 0 for nid in shown}
    for _ in range(len(shown) + 1):
        changed = False
        for a, b in edges:
            if rank[b] < rank[a] + 1:
                rank[b] = rank[a] + 1
                changed = True
        if not changed:
            break
    max_rank = max(rank.values(), default=0)
    # Unlinked nodes: sources/playback to the left, sinks/captures to the right.
    linked_shown = {a for a, _ in edges} | {b for _, b in edges}
    for nid, o in shown.items():
        if nid in linked_shown:
            continue
        k = kind_of(o["info"]["props"])
        rank[nid] = max_rank if k in ("sink", "capture") else 0

    cols = {}
    for nid in sorted(shown):
        cols.setdefault(rank[nid], []).append(nid)

    def height(nid):
        n = max(len(node_ports[nid]["in"]), len(node_ports[nid]["out"]), 1)
        return HEAD_H + n * PORT_H + 8

    # Barycenter ordering: two sweeps to untangle crossings.
    order_y = {}
    for r in sorted(cols):
        y = PAD
        for nid in cols[r]:
            order_y[nid] = y
            y += height(nid) + ROW_GAP
    neigh = {nid: [] for nid in shown}
    for a, b in edges:
        neigh[a].append(b)
        neigh[b].append(a)
    for _ in range(2):
        for r in sorted(cols):
            def key(nid):
                ys = [order_y[m] for m in neigh[nid] if rank[m] != r]
                return sum(ys) / len(ys) if ys else order_y[nid]
            cols[r].sort(key=key)
            y = PAD
            for nid in cols[r]:
                order_y[nid] = y
                y += height(nid) + ROW_GAP

    # ---- build output ----------------------------------------------------
    out_nodes = {}
    port_pos = {}
    for r in sorted(cols):
        x = PAD + r * (NODE_W + COL_GAP)
        for nid in cols[r]:
            o = shown[nid]
            props = o["info"]["props"]
            y = order_y[nid]
            plist = []
            for d in ("in", "out"):
                for idx, (_, pid, pr) in enumerate(node_ports[nid][d]):
                    label = pr.get("audio.channel") or re.sub(r"^.*[:_]", "", pr.get("port.name", "")) or str(pid)
                    py = y + HEAD_H + idx * PORT_H + PORT_H / 2
                    px = x if d == "in" else x + NODE_W
                    port_pos[pid] = (px, py)
                    plist.append({"id": pid, "dir": d, "label": label, "x": px - x, "y": py - y})
            st = top.get(nid)
            out_nodes[str(nid)] = {
                "id": nid,
                "name": props.get("node.name", str(nid)),
                "title": props.get("node.description") or props.get("node.nick") or props.get("application.name") or props.get("node.name", str(nid)),
                "class": props.get("media.class", ""),
                "kind": kind_of(props),
                "state": o["info"].get("state", ""),
                "error": o["info"].get("error"),
                "x": x, "y": y, "w": NODE_W, "h": height(nid),
                "headH": HEAD_H,
                "ports": plist,
                "stats": st,
                "props": flat_props(props),
            }

    out_links = []
    for l in links:
        i = l["info"]
        a, b = i["output-port-id"], i["input-port-id"]
        if a in port_pos and b in port_pos:
            (x1, y1), (x2, y2) = port_pos[a], port_pos[b]
            out_links.append({
                "id": l["id"], "from": i["output-node-id"], "to": i["input-node-id"],
                "state": i.get("state", ""), "x1": x1, "y1": y1, "x2": x2, "y2": y2,
            })

    states = {"running": 0, "idle": 0, "suspended": 0, "error": 0}
    for o in nodes.values():
        s = o["info"].get("state", "")
        if s in states:
            states[s] += 1

    total_w = PAD * 2 + (max(cols) + 1) * NODE_W + max(cols) * COL_GAP if cols else 0
    total_h = max((order_y[n] + height(n) for n in shown), default=0) + PAD

    print(json.dumps({
        "clock": {
            "rate": settings.get("clock.rate"),
            "quantum": settings.get("clock.quantum"),
            "minQuantum": settings.get("clock.min-quantum"),
            "maxQuantum": settings.get("clock.max-quantum"),
            "forceQuantum": settings.get("clock.force-quantum"),
            "forceRate": settings.get("clock.force-rate"),
            "allowedRates": settings.get("clock.allowed-rates"),
        },
        "defaults": {
            "sink": (defaults.get("default.audio.sink") or {}).get("name", ""),
            "source": (defaults.get("default.audio.source") or {}).get("name", ""),
        },
        "wireplumber": {
            "autoswitch": sm.get("bluetooth.autoswitch-to-headset-profile"),
            "profilePreference": sm.get("bluetooth.profile-preference"),
            "followDefault": sm.get("linking.follow-default-target"),
        },
        "counts": {
            "nodes": len(nodes), "shown": len(shown), "links": len(links),
            "clients": n_clients, "devices": n_devices, **states,
            "xruns": sum((s or {}).get("errors", 0) for s in top.values()),
        },
        "width": total_w, "height": total_h,
        "nodes": out_nodes,
        "links": out_links,
    }))


if __name__ == "__main__":
    sys.exit(main())
