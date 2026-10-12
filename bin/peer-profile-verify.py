#!/usr/bin/env python3
"""Fix, then PROVE, every Claude Code profile dir peer-agent spawns into.

The fix half sets the flags that can block a non-interactive start: trust for
the spawn cwd, first-run onboarding, the CLAUDE.md-includes prompts, and the
settings a fresh profile would otherwise ask about.

The prove half is the point. "tmux made a session" is not evidence the session
works - tmux new-session -d returns 0 even when claude is parked on a prompt
forever. So each profile is launched exactly the way peer-agent launches it and
must produce a sessions/<pid>.json carrying a bridgeSessionId, which only
happens once Claude Code is fully up and registered with claude.ai. Anything
else is reported with the prompt it is stuck on.
"""
import json, os, re, subprocess, sys, time, glob, secrets
from pathlib import Path

HOME = Path.home()
PROFILES = [".claude", ".claude2", ".claude3", ".claude4"]
CLAUDE = HOME / ".local/bin/claude"
WAIT = int(os.environ.get("VERIFY_WAIT", "60"))

PROMPTS = [
    (r"trust the files|Do you trust",            "TRUST DIALOG"),
    (r"Dark mode|text style that looks best",    "THEME PICKER"),
    (r"Bypass Permissions mode",                 "BYPASS-PERMISSIONS WARNING"),
    (r"Select login method|Log in with|API key", "LOGIN / AUTH"),
    (r"external includes|CLAUDE\.md.*include",   "CLAUDE.md INCLUDES PROMPT"),
]

def jload(p):
    try: return json.loads(Path(p).read_text())
    except Exception: return None

def jsave(p, o):
    Path(p).write_text(json.dumps(o, indent=2)); os.chmod(p, 0o600)

def fix(prof):
    d = HOME / prof
    d.mkdir(mode=0o700, exist_ok=True)
    changed = []

    cfg_p = d / ".claude.json"
    cfg = jload(cfg_p)
    if cfg is None or not cfg.get("hasCompletedOnboarding"):
        base = jload(HOME / ".claude.json")
        if not base or not base.get("hasCompletedOnboarding"):
            return ["NO ONBOARDED ~/.claude.json TO SEED FROM"]
        cfg = dict(base)
        cfg["machineID"] = secrets.token_hex(32)
        cfg["userID"] = secrets.token_hex(32)
        changed.append("seeded .claude.json (fresh machineID/userID)")

    proj = cfg.setdefault("projects", {}).setdefault(str(HOME), {})
    for k, v in (("hasTrustDialogAccepted", True),
                 ("hasClaudeMdExternalIncludesApproved", True),
                 ("hasClaudeMdExternalIncludesWarningShown", True)):
        if proj.get(k) is not True:
            proj[k] = True; changed.append(k)
    if not isinstance(proj.get("projectOnboardingSeenCount"), int) or proj["projectOnboardingSeenCount"] < 1:
        proj["projectOnboardingSeenCount"] = 1; changed.append("projectOnboardingSeenCount")
    if not cfg.get("hasCompletedOnboarding"):
        cfg["hasCompletedOnboarding"] = True; changed.append("hasCompletedOnboarding")
    # Only write when something actually changed: a live session in this profile
    # rewrites .claude.json itself, and a needless write can race with it.
    if changed:
        jsave(cfg_p, cfg)

    creds, src = d / ".credentials.json", HOME / ".claude/.credentials.json"
    if not creds.exists() and src.exists():
        creds.write_bytes(src.read_bytes()); os.chmod(creds, 0o600)
        changed.append(".credentials.json")

    base_s = {k: v for k, v in (jload(HOME / ".claude/settings.json") or {}).items()}
    s_p = d / "settings.json"
    s = jload(s_p)
    before = dict(s) if s else None
    s = s or {}
    for k, v in base_s.items():
        s.setdefault(k, v)
    s.setdefault("skipDangerousModePermissionPrompt", True)
    if s.get("remoteControlAtStartup") is not True:
        s["remoteControlAtStartup"] = True; changed.append("remoteControlAtStartup")
    if s != before:
        jsave(s_p, s)
    return changed

def dedupe():
    seen = {"machineID": set(), "userID": set()}
    for p in [HOME / ".claude.json"] + [HOME / n / ".claude.json" for n in PROFILES]:
        cfg = jload(p)
        if cfg is None: continue
        ch = False
        for k in seen:
            v = cfg.get(k)
            if v is None: continue
            if v in seen[k]:
                cfg[k] = secrets.token_hex(32); ch = True
            seen[k].add(cfg[k])
        if ch: jsave(p, cfg)

def verify(prof):
    sess = f"verify-{prof.lstrip('.')}-{secrets.token_hex(2)}"
    cdir = str(HOME / prof)
    subprocess.run(["tmux", "kill-session", "-t", sess],
                   capture_output=True)
    r = subprocess.run(["tmux", "new-session", "-d", "-s", sess,
                        "-e", f"CLAUDE_CONFIG_DIR={cdir}", "--",
                        str(CLAUDE), "--dangerously-skip-permissions"],
                       capture_output=True, cwd=str(HOME))
    if r.returncode != 0:
        return "SPAWN FAILED", r.stderr.decode()[:120]

    deadline = time.time() + WAIT
    while time.time() < deadline:
        time.sleep(3)
        for f in glob.glob(os.path.join(cdir, "sessions", "*.json")):
            d = jload(f)
            if d and (d.get("tmux") or "").startswith(sess) and d.get("bridgeSessionId"):
                subprocess.run(["tmux", "kill-session", "-t", sess], capture_output=True)
                return "OK", d["bridgeSessionId"][:24]

    screen = subprocess.run(["tmux", "capture-pane", "-p", "-t", sess],
                            capture_output=True).stdout.decode("utf-8", "replace")
    subprocess.run(["tmux", "kill-session", "-t", sess], capture_output=True)
    for pat, label in PROMPTS:
        if re.search(pat, screen, re.I):
            return "BLOCKED", label
    reg = [f for f in glob.glob(os.path.join(cdir, "sessions", "*.json"))
           if (jload(f) or {}).get("tmux", "").startswith(sess)]
    if reg:
        return "NO BRIDGE", "started but never registered with claude.ai"
    return "STUCK", " | ".join([l.strip() for l in screen.splitlines() if l.strip()][-2:])[:100]

print(f"host={os.uname().nodename} home={HOME}")
for prof in PROFILES:
    print(f"  fix {prof:9s} {'; '.join(fix(prof)) or 'already correct'}")
dedupe()
print("  -- launching each profile exactly as peer-agent does --")
for prof in PROFILES:
    st, detail = verify(prof)
    print(f"  {prof:9s} {st:10s} {detail}")
