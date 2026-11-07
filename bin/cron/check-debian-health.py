#!/usr/bin/env python3
"""Debian security + system-health check across our key-reachable servers.

Deterministic (no LLM): streams debian-health-probe.sh over ssh to each host in
~/.config/debian-health/hosts.json, evaluates findings, diffs security-posture
fingerprints against the previous run, and emails baleti3266@gmail.com when
something needs attention (deduped; reminder after 7 days if still unresolved).

Scheduling: the systemd timer fires daily; this script decides whether a run
is due. Interval adapts: 1 day while any critical finding / unreachable host,
2 days normally, 3 after 4 clean runs, 4 after 8 clean runs.

  --force   run now regardless of schedule
  --dry     print report, send no mail, don't touch state
"""
import hashlib, json, subprocess, sys, time, traceback
from datetime import datetime
from pathlib import Path

HOME = Path.home()
CFG = HOME / ".config/debian-health/hosts.json"
STATE_DIR = HOME / ".local/share/debian-health-check"
STATE = STATE_DIR / "state.json"
LOGS = STATE_DIR / "logs"
PROBE = HOME / "bin/cron/debian-health-probe.sh"
MAIL = HOME / ".config/claude-email/mail"
TO = "baleti3266@gmail.com"
REMIND_S = 7 * 86400
DRIFT_KEYS = ["LISTENERS", "UID0_USERS", "LOGIN_USERS", "SUDO_GROUP", "AUTHKEYS_SHA",
              "ROOT_AUTHKEYS_READABLE", "SSHD_ROOT_LOGIN", "SSHD_PASSWORD_AUTH",
              "CRON_SHA", "SUID_SHA", "FIREWALL", "FAIL2BAN"]
SSH_OPTS = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "-o", "ServerAliveInterval=10"]


def probe(host):
    argv = ["ssh", *SSH_OPTS, *host["ssh"]]
    r = subprocess.run(argv, input=PROBE.read_text(), capture_output=True, text=True, timeout=180)
    if r.returncode != 0 or "HOSTNAME=" not in r.stdout:
        raise RuntimeError(f"ssh/probe failed rc={r.returncode}: {(r.stderr or r.stdout).strip()[:300]}")
    return dict(l.split("=", 1) for l in r.stdout.splitlines() if "=" in l)


def num(d, k, default=0.0):
    try:
        return float(d.get(k, default))
    except ValueError:
        return default


def evaluate(name, d, prev):
    """-> list of (severity, message). severity: CRIT | WARN"""
    f = []
    sec = [p for p in d.get("SECURITY_PENDING", "").split(";") if p]
    if sec:
        f.append(("CRIT", f"{len(sec)} security update(s) pending: {', '.join(sec[:12])}"))
    if d.get("UU_ENABLED") != "yes":
        f.append(("CRIT", "unattended-upgrades is not enabled"))
    if d.get("APT_TIMERS_ACTIVE") != "active":
        f.append(("WARN", f"apt-daily timers not both active ({d.get('APT_TIMERS_ACTIVE')})"))
    n = num(d, "UU_LAST_RUN_AGE_H", -1)
    if n > 72:
        f.append(("WARN", f"unattended-upgrades log untouched for {int(n)}h"))
    if d.get("UU_RECENT_ERRORS"):
        f.append(("WARN", f"unattended-upgrades errors: {d['UU_RECENT_ERRORS'][:200]}"))
    if num(d, "APT_LISTS_AGE_H", 0) > 72:
        f.append(("WARN", f"apt package lists {int(num(d,'APT_LISTS_AGE_H'))}h old (apt update not running?)"))
    if d.get("REBOOT_REQUIRED") == "yes":
        f.append(("WARN", f"reboot required ({d.get('REBOOT_PKGS','')[:80]}); uptime {d.get('UPTIME_DAYS')}d"))
    elif d.get("KERNEL_NEWEST_INSTALLED") and d.get("KERNEL_RUNNING") != d.get("KERNEL_NEWEST_INSTALLED"):
        f.append(("WARN", f"running kernel {d['KERNEL_RUNNING']} older than installed {d['KERNEL_NEWEST_INSTALLED']}"))
    if d.get("SYSTEMD_STATE") not in ("running", ""):
        f.append(("WARN", f"systemd state: {d.get('SYSTEMD_STATE')}"))
    if d.get("FAILED_UNITS"):
        f.append(("WARN", f"failed units: {d['FAILED_UNITS']}"))
    if d.get("TIME_SYNCED") == "no":
        f.append(("WARN", "clock not NTP-synchronised"))
    if d.get("DISK_HIGH"):
        f.append(("CRIT", f"disk >=85% used: {d['DISK_HIGH']}"))
    if d.get("INODE_HIGH"):
        f.append(("CRIT", f"inodes >=90% used: {d['INODE_HIGH']}"))
    if num(d, "SWAP_USED_PCT") > 90 and num(d, "MEM_AVAIL_PCT", 100) < 15:
        f.append(("WARN", f"memory pressure: swap {d['SWAP_USED_PCT']}% used, {d['MEM_AVAIL_PCT']}% RAM available"))
    if num(d, "LOAD1") > 2 * max(num(d, "NCPU", 1), 1):
        f.append(("WARN", f"load {d['LOAD1']} on {int(num(d,'NCPU'))} CPUs"))
    pk = int(num(prev, "OOM_KILLS_30D", 0)) if prev else None
    if pk is not None and num(d, "OOM_KILLS_30D") > pk:
        f.append(("WARN", f"OOM kills in last 30d rose {pk} -> {int(num(d,'OOM_KILLS_30D'))}"))
    z = d.get("ZFS", "")
    if z and "all pools are healthy" not in z:
        f.append(("CRIT", f"ZFS: {z[:200]}"))
    if d.get("MDADM"):
        f.append(("CRIT", f"mdadm degraded: {d['MDADM']}"))
    if d.get("SSHD_PASSWORD_AUTH") == "yes":
        f.append(("CRIT", "sshd PasswordAuthentication is yes"))
    if d.get("SSHD_ROOT_LOGIN") in ("yes", "without-password", "prohibit-password"):
        f.append(("WARN", f"sshd PermitRootLogin {d['SSHD_ROOT_LOGIN']}"))
    if d.get("UID0_USERS", "root") != "root":
        f.append(("CRIT", f"extra UID 0 accounts: {d['UID0_USERS']}"))
    if num(d, "SSH_FAILED_24H") > 500:
        f.append(("WARN", f"{int(num(d,'SSH_FAILED_24H'))} failed ssh logins in 24h"))
    if prev:
        for k in DRIFT_KEYS:
            if k in prev and prev.get(k) != d.get(k):
                f.append(("CRIT", f"DRIFT {k}: '{prev.get(k,'')[:120]}' -> '{d.get(k,'')[:120]}'"))
    return f


def send(subject, body):
    subprocess.run([str(MAIL), "send", "--to", TO, "--subject", subject, "--body", body],
                   check=True, capture_output=True, text=True, timeout=120)


def next_interval(crit, unreachable, streak):
    if crit or unreachable:
        return 1
    if streak >= 8:
        return 4
    if streak >= 4:
        return 3
    return 2


def main():
    force = "--force" in sys.argv
    dry = "--dry" in sys.argv
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    LOGS.mkdir(exist_ok=True)
    state = json.loads(STATE.read_text()) if STATE.exists() else {}
    now = time.time()
    due_at = state.get("last_run", 0) + state.get("interval_days", 2) * 86400 - 3600  # 1h slack for timer jitter
    if not force and not dry and now < due_at:
        print(f"not due until {datetime.fromtimestamp(due_at + 3600):%F %H:%M} (interval {state.get('interval_days')}d)")
        return

    hosts = json.loads(CFG.read_text())
    hstate = state.get("hosts", {})
    report, findings, unreachable = [], [], []
    for h in hosts:
        name = h["name"]
        try:
            d = probe(h)
        except Exception as e:  # noqa: BLE001
            fails = hstate.get(name, {}).get("fails", 0) + 1
            hstate.setdefault(name, {})["fails"] = fails
            if h.get("optional"):  # e.g. a VM that is intentionally stopped: note it, don't alert
                report.append(f"## {name}: unreachable (optional host, not counted) ({str(e)[:120]})")
                continue
            unreachable.append(name)
            findings.append((name, "CRIT" if fails >= 2 else "WARN", f"unreachable/probe failed (x{fails}): {e}"))
            report.append(f"## {name}: UNREACHABLE ({e})")
            continue
        prev = hstate.get(name, {}).get("probe")  # None on first run -> baseline silently
        fs = evaluate(name, d, prev)
        for sev, msg in fs:
            findings.append((name, sev, msg))
        hstate[name] = {"probe": d, "fails": 0}
        report.append(f"## {name}: " + ("OK" if not fs else f"{len(fs)} finding(s)") +
                      f"  [up {d.get('UPTIME_DAYS')}d, kernel {d.get('KERNEL_RUNNING')}, pending {d.get('UPGRADABLE_N')}]" +
                      ("" if prev else "  (baseline recorded)"))

    crit = [f for f in findings if f[1] == "CRIT"]
    lines = [f"[{sev}] {n}: {m}" for n, sev, m in findings]
    text = "\n".join(report) + ("\n\nFindings:\n" + "\n".join(lines) if lines else "\n\nAll clean.")
    print(text)
    if dry:
        return

    streak = 0 if findings else state.get("clean_streak", 0) + 1
    interval = next_interval(bool(crit), bool(unreachable), streak)
    # dedupe: drift lines are one-shot (baseline moves on), others persist until fixed
    sig = hashlib.sha256("\n".join(sorted(lines)).encode()).hexdigest()[:16]
    should_mail = bool(findings) and (sig != state.get("last_alert_sig") or now - state.get("last_alert_ts", 0) > REMIND_S)
    if should_mail:
        send(f"Server health: {len(crit)} critical, {len(findings)-len(crit)} warning ({datetime.now():%F})",
             text + f"\n\nNext check in {interval} day(s) (adaptive: 1d while critical/unreachable).\n"
                    f"State: {STATE_DIR}\nHosts: {CFG}\nRe-run: ~/bin/cron/check-debian-health.py --force")
        state["last_alert_sig"], state["last_alert_ts"] = sig, now
    if not findings:
        state["last_alert_sig"] = ""
    state.update(last_run=now, interval_days=interval, clean_streak=streak, hosts=hstate)
    tmp = STATE.with_suffix(".tmp")
    tmp.write_text(json.dumps(state, indent=1))
    tmp.replace(STATE)
    (LOGS / f"{datetime.now():%F_%H%M%S}.log").write_text(text + f"\n\nnext interval: {interval}d, clean streak: {streak}\n")
    for old in sorted(LOGS.glob("*.log"))[:-60]:
        old.unlink()


if __name__ == "__main__":
    try:
        main()
    except Exception:  # the check itself failing must not be silent
        tb = traceback.format_exc()
        print(tb, file=sys.stderr)
        try:
            send(f"Debian health check FAILED to run ({datetime.now():%F})",
                 "check-debian-health.py crashed; servers were NOT checked this cycle.\n\n" + tb[-3000:])
        except Exception:  # noqa: BLE001
            pass
        sys.exit(1)
