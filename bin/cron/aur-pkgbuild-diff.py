#!/usr/bin/env python3
"""
For every installed AUR package, fetches its current PKGBUILD from the AUR
and diffs it against the last snapshot this script saved, writing one diff
file per package that needs review.

This is the deterministic half of the AUR security check: it does the actual
fetching/diffing so the LLM reviewer isn't relying on web search to guess
what changed. Crucially, it does NOT only look at packages with a pending
update - a package sitting at its current (unreviewed) version is not
presumed safe, since nothing before this script ever actually inspected
PKGBUILD content. Every package without a prior snapshot gets its full
current PKGBUILD queued for a from-scratch review, whether or not an update
is pending, so the first several runs amount to a full backlog audit of
everything already installed - not just a going-forward diff.
"""
import json
import re
import subprocess
import sys
import urllib.request
from pathlib import Path

STATEDIR = Path.home() / ".local/share/aur-security-check"
SNAPDIR = STATEDIR / "pkgbuild-snapshots"
DIFFDIR = STATEDIR / "pending-diffs"

AUR_RPC = "https://aur.archlinux.org/rpc/v5/info"
AUR_RAW_PKGBUILD = "https://aur.archlinux.org/cgit/aur.git/plain/PKGBUILD?h={pkg}"


def installed_aur_packages():
    out = subprocess.run(["pacman", "-Qm"], capture_output=True, text=True, check=True).stdout
    pkgs = {}
    for line in out.strip().splitlines():
        name, ver = line.split(" ", 1)
        pkgs[name] = ver
    return pkgs


def aur_versions(pkg_names):
    versions = {}
    # AUR RPC caps arg[] count per request; chunk to be safe.
    chunk_size = 100
    names = list(pkg_names)
    for i in range(0, len(names), chunk_size):
        chunk = names[i:i + chunk_size]
        query = "&".join(f"arg[]={n}" for n in chunk)
        url = f"{AUR_RPC}?{query}"
        with urllib.request.urlopen(url, timeout=30) as resp:
            data = json.load(resp)
        for result in data.get("results", []):
            versions[result["Name"]] = result["Version"]
    return versions


def vercmp(installed, aur):
    result = subprocess.run(["vercmp", installed, aur], capture_output=True, text=True, check=True)
    return int(result.stdout.strip())


def fetch_pkgbuild(pkg):
    url = AUR_RAW_PKGBUILD.format(pkg=pkg)
    with urllib.request.urlopen(url, timeout=30) as resp:
        return resp.read().decode("utf-8", errors="replace")


def main():
    SNAPDIR.mkdir(parents=True, exist_ok=True)
    if DIFFDIR.exists():
        for f in DIFFDIR.glob("*"):
            f.unlink()
    DIFFDIR.mkdir(parents=True, exist_ok=True)

    installed = installed_aur_packages()
    if not installed:
        print("No AUR packages installed.")
        return

    try:
        latest = aur_versions(installed.keys())
    except Exception as e:
        print(f"ERROR: failed to query AUR RPC: {e}", file=sys.stderr)
        sys.exit(1)

    pending_update = set()
    for name, inst_ver in installed.items():
        aur_ver = latest.get(name)
        if aur_ver is None:
            continue  # not an AUR-tracked pkg (e.g. local/manual install), skip
        try:
            if vercmp(inst_ver, aur_ver) < 0:
                pending_update.add(name)
        except subprocess.CalledProcessError:
            continue

    print(f"{len(installed)} AUR packages installed, {len(pending_update)} have a pending update.")

    # Every AUR-tracked installed package is a candidate for review, not just
    # ones with an update pending - a package already at its "latest" version
    # may never have had its PKGBUILD actually inspected before.
    candidates = [n for n in installed if n in latest]

    reviewed = []
    for name in candidates:
        inst_ver = installed[name]
        aur_ver = latest[name]
        try:
            new_pkgbuild = fetch_pkgbuild(name)
        except Exception as e:
            print(f"WARN: could not fetch PKGBUILD for {name}: {e}", file=sys.stderr)
            continue

        snap_path = SNAPDIR / f"{name}.PKGBUILD"
        diff_path = DIFFDIR / f"{name}.diff"

        if snap_path.exists():
            old_pkgbuild = snap_path.read_text(errors="replace")
            if old_pkgbuild == new_pkgbuild:
                snap_path.write_text(new_pkgbuild)
                continue  # unchanged since last review - nothing new
            diff = subprocess.run(
                ["diff", "-u", "--label", f"{name}/PKGBUILD (last reviewed)",
                 "--label", f"{name}/PKGBUILD (now, installed {inst_ver}, AUR has {aur_ver})",
                 str(snap_path), "-"],
                input=new_pkgbuild, capture_output=True, text=True,
            ).stdout
            diff_path.write_text(diff)
            reviewed.append((name, "diff", inst_ver, aur_ver))
        else:
            # No prior snapshot: either never seen before, or (most runs
            # for a while) part of the initial backlog audit of every AUR
            # package already installed on this machine. Review it whole -
            # this is not presumed safe just because it predates the check.
            update_note = (f"an update is pending ({inst_ver} -> {aur_ver})"
                            if name in pending_update else
                            f"currently installed at {inst_ver}, matching AUR's latest")
            diff_path.write_text(
                f"--- NO PRIOR SNAPSHOT: full PKGBUILD for from-scratch review ---\n"
                f"{name} ({update_note})\n\n{new_pkgbuild}"
            )
            reviewed.append((name, "first-seen", inst_ver, aur_ver))

        snap_path.write_text(new_pkgbuild)

    for name, kind, inst_ver, aur_ver in reviewed:
        print(f"  {name}: {inst_ver} -> {aur_ver} ({kind}) -> {DIFFDIR / (name + '.diff')}")

    if not reviewed:
        print("No PKGBUILD changes to review (either no pending updates, or text identical to last snapshot).")


if __name__ == "__main__":
    main()
