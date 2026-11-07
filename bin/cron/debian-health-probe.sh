#!/bin/sh
# Read-only, unprivileged health/security probe. Streamed over ssh to a Debian
# host by check-debian-health.py; prints KEY=VALUE lines (multi-values joined
# with ';'). Must never modify anything and must not need root.
LC_ALL=C; export LC_ALL
kv() { printf '%s=%s\n' "$1" "$2"; }
join() { tr '\n' ';' | sed 's/;$//'; }

kv HOSTNAME "$(hostname)"
kv UPTIME_DAYS "$(awk '{print int($1/86400)}' /proc/uptime)"
kv LOAD1 "$(cut -d' ' -f1 /proc/loadavg)"
kv NCPU "$(nproc)"
kv MEM_AVAIL_PCT "$(awk '/MemTotal/{t=$2}/MemAvailable/{a=$2}END{printf "%d", a*100/t}' /proc/meminfo)"
kv SWAP_USED_PCT "$(awk '/SwapTotal/{t=$2}/SwapFree/{f=$2}END{if(t>0)printf "%d",(t-f)*100/t; else print 0}' /proc/meminfo)"

# disks: fs >= 85% used (blocks) or >= 90% inodes
kv DISK_HIGH "$(df -P -x tmpfs -x devtmpfs -x squashfs -x overlay 2>/dev/null | awk 'NR>1{gsub("%","",$5); if($5+0>=85) printf "%s=%s%%\n",$6,$5}' | join)"
kv INODE_HIGH "$(df -Pi -x tmpfs -x devtmpfs -x squashfs -x overlay 2>/dev/null | awk 'NR>1{gsub("%","",$5); if($5+0>=90) printf "%s=%s%%\n",$6,$5}' | join)"

# pending updates (uses the already-fetched apt lists; no root, no network)
UPG=$(apt-get -s -o Debug::NoLocking=1 upgrade 2>/dev/null | grep '^Inst ')
kv UPGRADABLE_N "$(printf '%s' "$UPG" | grep -c .)"
kv SECURITY_PENDING "$(printf '%s\n' "$UPG" | grep -i 'security' | awk '{print $2}' | join)"
kv APT_LISTS_AGE_H "$(f=$(ls -t /var/lib/apt/lists/*_Packages* /var/lib/apt/lists/*_InRelease 2>/dev/null | head -1); [ -n "$f" ] && echo $(( ($(date +%s) - $(stat -c %Y "$f")) / 3600 )) || echo -1)"

# reboot needed / kernel lag
kv REBOOT_REQUIRED "$([ -e /var/run/reboot-required ] && echo yes || echo no)"
kv REBOOT_PKGS "$(cat /var/run/reboot-required.pkgs 2>/dev/null | sort -u | join)"
RUN=$(uname -r)
NEWEST=$(dpkg-query -W -f='${Package}\n' 'linux-image-[0-9]*' 2>/dev/null | sed 's/^linux-image-//; s/-unsigned$//' | sort -V | tail -1)
kv KERNEL_RUNNING "$RUN"
kv KERNEL_NEWEST_INSTALLED "$NEWEST"

# unattended-upgrades health
kv UU_ENABLED "$(grep -rhs 'Unattended-Upgrade "1"' /etc/apt/apt.conf.d/ | head -1 | grep -q . && echo yes || echo no)"
UULOG=/var/log/unattended-upgrades/unattended-upgrades.log
if [ -r "$UULOG" ]; then
  kv UU_LAST_RUN_AGE_H "$(echo $(( ($(date +%s) - $(stat -c %Y "$UULOG")) / 3600 )))"
  kv UU_RECENT_ERRORS "$(tail -n 200 "$UULOG" | grep -E ' ERROR ' | tail -3 | cut -c1-160 | join)"
else
  kv UU_LAST_RUN_AGE_H -1
fi
kv APT_TIMERS_ACTIVE "$(systemctl is-active apt-daily.timer apt-daily-upgrade.timer 2>/dev/null | sort -u | join)"

# services / system state
kv SYSTEMD_STATE "$(systemctl is-system-running 2>/dev/null)"
kv FAILED_UNITS "$(systemctl --failed --no-legend --plain 2>/dev/null | awk '{print $1}' | join)"
kv TIME_SYNCED "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)"
kv OOM_KILLS_30D "$(journalctl -k --since '30 days ago' --no-pager -q 2>/dev/null | grep -c 'Out of memory: Killed')"
kv JOURNAL_READABLE "$(journalctl -n1 --no-pager -q >/dev/null 2>&1 && echo yes || echo no)"
kv SSH_FAILED_24H "$(journalctl -u ssh -u sshd --since '24 hours ago' --no-pager -q 2>/dev/null | grep -c 'Failed password\|Invalid user')"
kv ZFS "$(command -v zpool >/dev/null && zpool status -x 2>/dev/null | head -3 | join)"
kv MDADM "$(grep -E '\[.*_.*\]' /proc/mdstat 2>/dev/null | join)"

# security posture / drift fingerprints (compared with the previous run by the runner)
kv LISTENERS "$(ss -H -tuln 2>/dev/null | awk '{print $1":"$5}' | sed 's/%[A-Za-z0-9_.-]*//' | grep -v -E ':(127\.|\[::1\]|::1)|:(68|546)$|^udp:\[fe80' | sort -u | join)"
kv UID0_USERS "$(awk -F: '$3==0{print $1}' /etc/passwd | join)"
kv LOGIN_USERS "$(awk -F: '$7 !~ /(nologin|false)$/ {print $1}' /etc/passwd | sort | join)"
kv SUDO_GROUP "$(getent group sudo | cut -d: -f4)"
kv AUTHKEYS_SHA "$(cat "$HOME/.ssh/authorized_keys" 2>/dev/null | sha256sum | cut -c1-16)"
kv ROOT_AUTHKEYS_READABLE "$([ -r /root/.ssh/authorized_keys ] && sha256sum /root/.ssh/authorized_keys | cut -c1-16 || echo n/a)"
sshcfg() { cat /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf 2>/dev/null | awk -v k="$1" 'tolower($1)==k && !seen {print $2; seen=1}'; }
kv SSHD_ROOT_LOGIN "$(sshcfg permitrootlogin)"
kv SSHD_PASSWORD_AUTH "$(sshcfg passwordauthentication)"
kv CRON_SHA "$(cat /etc/crontab /etc/cron.d/* 2>/dev/null | sha256sum | cut -c1-16)"
kv SUID_SHA "$(find /usr/bin /usr/sbin /bin /sbin /usr/local -xdev -perm -4000 -type f 2>/dev/null | sort | sha256sum | cut -c1-16)"
kv FIREWALL "$( (command -v ufw >/dev/null && systemctl is-active ufw 2>/dev/null) || (command -v nft >/dev/null && echo nft-present) || echo none)"
kv FAIL2BAN "$(systemctl is-active fail2ban 2>/dev/null)"
