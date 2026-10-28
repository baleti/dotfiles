#!/usr/bin/env python3
"""One-shot audio state snapshot for AudioSvc.qml: prints a single JSON object.

Everything comes from `pactl --format=json` (the pipewire-pulse shim), so one
query covers default sink/source, their volume/mute, per-app streams, and every
Bluetooth card with its selectable profiles.
"""
import json
import subprocess
import sys


def pactl(*args):
    try:
        out = subprocess.run(["pactl", "--format=json", *args], capture_output=True,
                             text=True, timeout=3).stdout
        return json.loads(out)
    except Exception:
        return None


def fraction(dev):
    # Mean of the channel percentages; 1.0 == 100%.
    vols = [v.get("value_percent", "0%") for v in (dev.get("volume") or {}).values()]
    nums = [float(v.rstrip("%")) for v in vols if v.rstrip("%").replace(".", "", 1).isdigit()]
    return round(sum(nums) / len(nums) / 100, 3) if nums else 0.0


def device(devs, name):
    for d in devs or []:
        if d.get("name") == name:
            return d
    return None


def is_bt(props):
    return props.get("device.api") == "bluez5" or props.get("api.bluez5.address") is not None


def main():
    info = pactl("info") or {}
    sinks = pactl("list", "sinks") or []
    sources = pactl("list", "sources") or []
    cards = pactl("list", "cards") or []
    sink_inputs = pactl("list", "sink-inputs") or []
    source_outputs = pactl("list", "source-outputs") or []

    sink = device(sinks, info.get("default_sink_name"))
    # Default source may be the sink's monitor; that still reports fine.
    source = device(sources, info.get("default_source_name"))

    def apps(streams):
        names = []
        for s in streams:
            n = (s.get("properties") or {}).get("application.name") or "?"
            if n not in names:
                names.append(n)
        return names

    bt_cards = []
    for c in cards:
        props = c.get("properties") or {}
        if not is_bt(props):
            continue
        profiles = []
        for pname, p in (c.get("profiles") or {}).items():
            if pname == "off":
                continue
            profiles.append({
                "name": pname,
                "description": p.get("description", pname),
                "available": bool(p.get("available", True)),
                "priority": p.get("priority", 0),
                "sinks": p.get("n_sinks", 0),
                "sources": p.get("n_sources", 0),
            })
        profiles.sort(key=lambda p: -p["priority"])
        bt_cards.append({
            "name": c.get("name"),
            "description": props.get("device.description") or props.get("device.alias") or c.get("name"),
            "address": props.get("api.bluez5.address", ""),
            "activeProfile": c.get("active_profile", ""),
            "profiles": profiles,
        })

    def devices(devs, default_name):
        out = []
        for d in devs:
            if d.get("name", "").endswith(".monitor") or d.get("monitor_of_sink") not in (None, 4294967295):
                continue  # skip sink monitors; they aren't mics
            props = d.get("properties") or {}
            out.append({
                "name": d.get("name", ""),
                "description": d.get("description", ""),
                "volume": fraction(d),
                "muted": bool(d.get("mute", False)),
                "bluetooth": is_bt(props),
                "card": props.get("device.name", ""),
                "cardDescription": props.get("device.description", ""),
                "default": d.get("name") == default_name,
            })
        return out

    sink_props = (sink or {}).get("properties") or {}
    print(json.dumps({
        "server": info.get("server_name", ""),
        "sink": {
            "name": (sink or {}).get("name", ""),
            "description": (sink or {}).get("description", ""),
            "volume": fraction(sink) if sink else 0.0,
            "muted": bool((sink or {}).get("mute", False)),
            "bluetooth": is_bt(sink_props) if sink else False,
            "card": sink_props.get("device.name", ""),
        },
        "source": {
            "name": (source or {}).get("name", ""),
            "description": (source or {}).get("description", ""),
            "volume": fraction(source) if source else 0.0,
            "muted": bool((source or {}).get("mute", False)),
            "monitor": bool((source or {}).get("monitor_of_sink") is not None
                            and (source or {}).get("monitor_of_sink") != 4294967295),
        },
        "sinks": devices(sinks, info.get("default_sink_name")),
        "sources": devices(sources, info.get("default_source_name")),
        "playbackApps": apps(sink_inputs),
        "captureApps": apps(source_outputs),
        "btCards": bt_cards,
    }))


if __name__ == "__main__":
    sys.exit(main())
