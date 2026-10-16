#!/usr/bin/env python3
"""fanwatch helper: ONE filesystem-wide fanotify mark on a btrfs volume, as resolved path events on a unix socket.

Runs as the desktop user with just CAP_SYS_ADMIN (to place the mark) and CAP_DAC_READ_SEARCH (to turn the
file handles in events into paths), see fanwatch-helper.service. Everything else (which paths matter,
debouncing, the catalog database, the search server) lives in the unprivileged user-side watcher
(catalog/watcher.py), which connects to the socket. This file is deliberately small and is installed
root-owned in /usr/local/lib/fanwatch so that nothing running as the user can change what holds the capabilities.

Why the top-level subvolume: fanotify refuses a filesystem mark placed inside a btrfs subvolume (EXDEV); one
mark placed through the top-level subvolume (subvolid=5, mounted read-only at TOP by the unit's root pre-step)
covers every subvolume. Once the mark is placed and a descriptor on that mount is open, the helper detaches the
mount (umount2 MNT_DETACH): the mark belongs to the filesystem, not to the mount, and the open descriptor keeps
the detached mount alive for turning event handles into paths (they then read /@home/user1/x, without TOP).
A startup self-test makes a file and requires its event to arrive with the right path, so a kernel that treats
this differently makes the helper fail loudly instead of going quiet.
Events carry a handle of the parent directory plus the entry name; paths are then translated from the
top-level layout (/run/btrfs-top/@home/user1/x) to where the subvolumes are mounted (/home/user1/x).
Subvolumes that are not mounted anywhere (snapshots, swap) and ones mounted under $FANWATCH_HOME (separate
subvolumes for cache, sources, ... that the catalog does not index) are dropped here, early.

Output, one JSON object per line: {"e": "CW", "p": "/home/user1/x/y", "d": 1}
  e: C created, D deleted, F moved away, T moved in, A attributes changed, W closed after writing
  d: 1 when the entry is a directory
and {"overflow": 1} when events were lost (kernel queue full, or the client was too slow): rescan.
"""
import ctypes, ctypes.util, json, os, select, socket, struct, sys, time

TOP = os.environ.get("FANWATCH_TOP", "/run/btrfs-top")
DETACH = os.environ.get("FANWATCH_DETACH", "1") == "1"
CANARY_DIR = os.environ.get("FANWATCH_CANARY_DIR", "/var/tmp")
SOCK = os.environ.get("FANWATCH_SOCK", "/run/fanwatch/events.sock")
HOME = os.environ.get("FANWATCH_HOME", "/home/user1").rstrip("/")

libc = ctypes.CDLL(ctypes.util.find_library("c"), use_errno=True)
libc.syscall.restype = ctypes.c_long
FAN_ATTRIB, FAN_CLOSE_WRITE, FAN_MOVED_FROM, FAN_MOVED_TO = 0x4, 0x8, 0x40, 0x80
FAN_CREATE, FAN_DELETE, FAN_Q_OVERFLOW, FAN_ONDIR = 0x100, 0x200, 0x4000, 0x40000000
FAN_REPORT_DIR_FID, FAN_REPORT_NAME, FAN_NONBLOCK, FAN_CLOEXEC = 0x400, 0x800, 0x2, 0x1
MASK = FAN_ATTRIB | FAN_CLOSE_WRITE | FAN_MOVED_FROM | FAN_MOVED_TO | FAN_CREATE | FAN_DELETE | FAN_ONDIR
LETTERS = ((FAN_CREATE, "C"), (FAN_DELETE, "D"), (FAN_MOVED_FROM, "F"), (FAN_MOVED_TO, "T"), (FAN_ATTRIB, "A"), (FAN_CLOSE_WRITE, "W"))

class FileHandle(ctypes.Structure):
    _fields_ = [("handle_bytes", ctypes.c_uint), ("handle_type", ctypes.c_int), ("f_handle", ctypes.c_ubyte * 128)]

def log(*a):
    print(*a, file=sys.stderr, flush=True)

def unescape(s):
    return s.replace("\\040", " ").replace("\\011", "\t").replace("\\012", "\n").replace("\\134", "\\")

def mountinfo():
    """[(root inside the filesystem, mount point, source device)] for every btrfs mount."""
    out = []
    for line in open("/proc/self/mountinfo"):
        f = line.split()
        sep = f.index("-")
        if f[sep + 1] == "btrfs":
            out.append((unescape(f[3]), unescape(f[4]), f[sep + 2]))
    return out

def check_top():
    """Refuse to go on unless TOP really is the top-level subvolume of the volume that holds / (marking a
    plain directory would silently watch the wrong filesystem)."""
    mi = mountinfo()
    root_src = next((src for r, mp, src in mi if mp == "/"), None)
    if not any(mp == TOP and r == "/" and src == root_src for r, mp, src in mi):
        sys.exit(f"{TOP} is not the mounted btrfs top-level subvolume of the volume holding /")

def subvolumes():
    """[(subvolume path inside the top level, where it is mounted)] for every mount of the volume holding /
    (matched by source device: each subvolume mount has its own device number)."""
    mi = mountinfo()
    root_src = next((src for r, mp, src in mi if mp == "/"), None)
    return sorted(((r, mp) for r, mp, src in mi if r != "/" and src == root_src and mp != TOP), key=lambda x: -len(x[0]))

class Mapper:
    def __init__(self):
        self.refresh()

    def refresh(self):
        self.subs = subvolumes()
        self.skip = [r for r, mp in self.subs if mp.startswith(HOME + "/")]
        self.stamp = time.time()

    def translate(self, top_path):
        """/run/btrfs-top/@home/user1/x -> /home/user1/x ; None for unmounted or skipped subvolumes."""
        rel = top_path[len(TOP):] if top_path.startswith(TOP + "/") else top_path
        if not rel.startswith("/@"):
            return None
        for root, mp in self.subs:
            if rel == root or rel.startswith(root + "/"):
                if root in self.skip:
                    return None
                tail = rel[len(root):]
                return (mp.rstrip("/") + tail) if mp != "/" else (tail or "/")
        return None

def decode(buf, mount_fd, mapper):
    """Yield ("overflow", None) or (mask, real path or None) for every event in a read() buffer."""
    off = 0
    while off < len(buf):
        evlen, _vers, _res, mlen, mask, _efd, _pid = struct.unpack_from("IBBHQii", buf, off)
        ioff, end, path, name = off + mlen, off + evlen, None, None
        off = end
        if mask & FAN_Q_OVERFLOW:
            yield "overflow", None
            continue
        while ioff < end:
            itype, _pad, ilen = struct.unpack_from("BBH", buf, ioff)
            if itype in (2, 3):          # directory handle (+ entry name)
                hb, ht = struct.unpack_from("Ii", buf, ioff + 12)
                h = FileHandle()
                h.handle_bytes, h.handle_type = hb, ht
                ctypes.memmove(h.f_handle, bytes(buf[ioff + 20: ioff + 20 + hb]), hb)
                r = libc.syscall(304, mount_fd, ctypes.byref(h), os.O_PATH)      # open_by_handle_at
                if r >= 0:
                    try:
                        path = os.readlink(f"/proc/self/fd/{r}")
                    except OSError:
                        pass
                    os.close(r)
                if itype == 2:
                    name = os.fsdecode(bytes(buf[ioff + 20 + hb: ioff + ilen]).split(b"\0", 1)[0])
            ioff += ilen
        if path is None or path.endswith(" (deleted)"):
            yield mask, None
            continue
        real = mapper.translate(path)
        if real is not None and name:
            real = real.rstrip("/") + "/" + name
        yield mask, real

def self_test(fd, mount_fd, mapper):
    """Make a file on the btrfs volume and require its creation event, with the right path, to come back."""
    path = os.path.join(CANARY_DIR, f".fanwatch-canary-{os.getpid()}")
    try:
        open(path, "w").close()
    except OSError as e:
        log(f"self-test skipped, cannot write {CANARY_DIR}: {e}")
        return
    ok, deadline = False, time.time() + 5
    try:
        while time.time() < deadline and not ok:
            if select.select([fd], [], [], 0.5)[0]:
                for mask, real in decode(os.read(fd, 1 << 18), mount_fd, mapper):
                    if real == path and mask & FAN_CREATE:
                        ok = True
    finally:
        try:
            os.unlink(path)
        except OSError:
            pass
        time.sleep(0.3)
        while select.select([fd], [], [], 0.1)[0]:
            os.read(fd, 1 << 18)
    if not ok:
        sys.exit("self-test failed: the creation event for a test file did not arrive with the expected path")
    log("self-test ok")

def main():
    check_top()                        # refuses to continue unless TOP is the btrfs top level
    fd = libc.fanotify_init(FAN_REPORT_DIR_FID | FAN_REPORT_NAME | FAN_NONBLOCK | FAN_CLOEXEC, os.O_RDONLY | os.O_LARGEFILE)
    if fd < 0:
        sys.exit(f"fanotify_init: {os.strerror(ctypes.get_errno())}")
    if libc.fanotify_mark(fd, 0x1 | 0x100, ctypes.c_uint64(MASK), -100, TOP.encode()) != 0:
        sys.exit(f"fanotify_mark on {TOP}: {os.strerror(ctypes.get_errno())}")
    mount_fd = os.open(TOP, os.O_RDONLY | os.O_DIRECTORY)
    if DETACH:
        # the mark belongs to the filesystem; the open descriptor keeps this mount alive for handle -> path
        if libc.umount2(TOP.encode(), 2) != 0:          # MNT_DETACH
            sys.exit(f"umount2({TOP}): {os.strerror(ctypes.get_errno())}")
    mapper = Mapper()
    self_test(fd, mount_fd, mapper)
    try:
        os.unlink(SOCK)
    except FileNotFoundError:
        pass
    srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    srv.bind(SOCK)
    os.chmod(SOCK, 0o600)
    srv.listen(1)
    srv.setblocking(False)
    client, lost = None, False
    sent = dropped = 0
    last_report = time.time()
    log(f"fanotify mark on the btrfs volume covering {len(mapper.subs)} mounted subvolumes "
        f"({'top-level mount detached' if DETACH else 'top-level mount kept'}), socket {SOCK}")

    def send(obj):
        nonlocal client, lost, sent, dropped
        if client is None:
            return
        try:
            client.send((json.dumps(obj) + "\n").encode())
            sent += 1
        except BlockingIOError:
            lost = True
            dropped += 1
        except OSError:
            client = None

    while True:
        ready, _, _ = select.select([fd, srv], [], [], 5.0)
        if srv in ready:
            try:
                c, _ = srv.accept()
                c.setblocking(False)
                if client is not None:
                    client.close()
                client, lost = c, False
                log("client connected")
            except BlockingIOError:
                pass
        if time.time() - mapper.stamp > 60:
            mapper.refresh()
        if time.time() - last_report > 3600:
            log(f"{sent} events sent, {dropped} dropped in the last hour")
            sent = dropped = 0
            last_report = time.time()
        if fd not in ready:
            continue
        try:
            buf = os.read(fd, 1 << 18)
        except BlockingIOError:
            continue
        for mask, real in decode(buf, mount_fd, mapper):
            if mask == "overflow":
                send({"overflow": 1})
                continue
            if real is None:
                continue
            if lost and client is not None:
                lost = False
                send({"overflow": 1})
            send({"e": "".join(l for bit, l in LETTERS if mask & bit), "p": real, "d": 1 if mask & FAN_ONDIR else 0})

if __name__ == "__main__":
    main()
