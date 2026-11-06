//! Unprivileged client for `netcap-helper` (the tiny privileged packet-metadata
//! process in ../netcap-helper). Replaces the per-interface `nethogs -t`
//! children, whose connection tables grew to ~400 MB each over a few weeks.
//!
//! sysmond stays fully unprivileged: it spawns the root-installed helper
//! (file capability cap_net_raw), reads its one-way stream of per-flow byte
//! counts, and does all the interpretation itself -- flow -> socket inode via
//! `/proc/net/{tcp,tcp6,udp,udp6}`, inode -> pid via `/proc/*/fd`. The stream
//! is treated as untrusted: strict framing, size caps, a read timeout, and any
//! violation kills and restarts the helper.
//!
//! Every table here is bounded (cache TTLs + hard caps), unlike nethogs'.

use std::collections::HashMap;
use std::fs;
use std::io::{self, Read};
use std::os::unix::fs::MetadataExt;
use std::os::unix::io::AsRawFd;
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};

pub const DEFAULT_HELPER: &str = "/usr/local/lib/sysmon/netcap-helper";
/// Overrides the helper path (tests / probe). Skips the root-ownership check.
pub const HELPER_ENV: &str = "SYSMON_NETCAP_HELPER";

// --- wire format (mirrors netcap-helper/src/wire.rs; golden-tested on both sides) ---
const MAGIC_HELLO: u32 = u32::from_le_bytes(*b"NCH1");
const MAGIC_TICK: u32 = u32::from_le_bytes(*b"NCP1");
const HEADER_LEN: usize = 16;
const RECORD_LEN: usize = 64;
const MAX_RECORDS: u32 = 20_000;

/// No frame for this long => helper considered hung.
const READ_TIMEOUT: Duration = Duration::from_secs(5);
const HELLO_TIMEOUT: Duration = Duration::from_secs(3);
const RESTART_BACKOFF: Duration = Duration::from_secs(5);

const RESOLVE_TTL: Duration = Duration::from_secs(30);
const NEGATIVE_TTL: Duration = Duration::from_secs(5);
const MAX_FLOW_CACHE: usize = 16384;
const FD_SCAN_MIN_GAP: Duration = Duration::from_millis(900);

const PROTO_TCP: u8 = 6;
const PROTO_UDP: u8 = 17;

/// (pid, process name, sent KB/s, recv KB/s) -- same shape the nethogs parser produced.
pub type Sample = (i32, String, f64, f64);
pub type TickReport = HashMap<String, Vec<Sample>>;

type Ip = [u8; 16]; // IPv4 stored v4-mapped (::ffff:a.b.c.d)

#[derive(Clone, Copy, PartialEq, Eq, Hash, Debug)]
struct Flow {
    proto: u8,
    lip: Ip,
    lport: u16,
    rip: Ip,
    rport: u16,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct Record {
    ifindex: u32,
    flow: Flow,
    sent: u64,
    recv: u64,
}

fn le32(b: &[u8]) -> u32 {
    u32::from_le_bytes([b[0], b[1], b[2], b[3]])
}
fn le64(b: &[u8]) -> u64 {
    u64::from_le_bytes([b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7]])
}

fn decode_record(b: &[u8]) -> Option<Record> {
    if b.len() != RECORD_LEN {
        return None;
    }
    // Reserved bytes must be zero: a cheap desync/corruption detector.
    if b[5..8].iter().any(|&x| x != 0) || b[44..48].iter().any(|&x| x != 0) {
        return None;
    }
    let proto = b[4];
    if proto != PROTO_TCP && proto != PROTO_UDP {
        return None;
    }
    let mut lip = [0u8; 16];
    let mut rip = [0u8; 16];
    lip.copy_from_slice(&b[8..24]);
    rip.copy_from_slice(&b[24..40]);
    Some(Record {
        ifindex: le32(&b[0..4]),
        flow: Flow { proto, lip, lport: u16::from_le_bytes([b[40], b[41]]), rip, rport: u16::from_le_bytes([b[42], b[43]]) },
        sent: le64(&b[48..56]),
        recv: le64(&b[56..64]),
    })
}

#[derive(Debug)]
enum FrameError {
    Io(io::Error),
    Protocol(&'static str),
}

/// Reads one tick frame: (elapsed_ms, records). Strict: wrong magic, an
/// oversized count or a malformed record is a protocol error.
fn read_tick<R: Read>(r: &mut R) -> Result<(u32, Vec<Record>), FrameError> {
    let mut h = [0u8; HEADER_LEN];
    r.read_exact(&mut h).map_err(FrameError::Io)?;
    if le32(&h[0..4]) != MAGIC_TICK {
        return Err(FrameError::Protocol("bad frame magic"));
    }
    let n = le32(&h[4..8]);
    if n > MAX_RECORDS {
        return Err(FrameError::Protocol("record count over cap"));
    }
    if le32(&h[12..16]) != 0 {
        return Err(FrameError::Protocol("reserved header field set"));
    }
    let mut body = vec![0u8; n as usize * RECORD_LEN];
    r.read_exact(&mut body).map_err(FrameError::Io)?;
    let mut recs = Vec::with_capacity(n as usize);
    for c in body.chunks_exact(RECORD_LEN) {
        recs.push(decode_record(c).ok_or(FrameError::Protocol("malformed record"))?);
    }
    Ok((le32(&h[8..12]), recs))
}

fn read_hello<R: Read>(r: &mut R) -> Result<(), FrameError> {
    let mut h = [0u8; HEADER_LEN];
    r.read_exact(&mut h).map_err(FrameError::Io)?;
    if le32(&h[0..4]) != MAGIC_HELLO || le32(&h[4..8]) != 0 {
        return Err(FrameError::Protocol("bad hello"));
    }
    Ok(())
}

// --- flow -> process resolution (all unprivileged) ---

fn v4(b: &[u8]) -> Ip {
    let mut ip = [0u8; 16];
    ip[10] = 0xff;
    ip[11] = 0xff;
    ip[12..16].copy_from_slice(&b[..4]);
    ip
}

fn is_wildcard(ip: &Ip) -> bool {
    ip.iter().all(|&b| b == 0) || (ip[..10].iter().all(|&b| b == 0) && ip[10] == 0xff && ip[11] == 0xff && ip[12..].iter().all(|&b| b == 0))
}

/// One `/proc/net/{tcp,udp}[6]` hex address (`0100007F:1F90`; v6 is 32 hex
/// digits in four host-endian words).
fn parse_hex_addr(s: &str) -> Option<(Ip, u16)> {
    let (a, p) = s.split_once(':')?;
    let port = u16::from_str_radix(p, 16).ok()?;
    let ip = match a.len() {
        8 => v4(&u32::from_str_radix(a, 16).ok()?.to_le_bytes()),
        32 => {
            let mut ip = [0u8; 16];
            for i in 0..4 {
                let w = u32::from_str_radix(&a[i * 8..i * 8 + 8], 16).ok()?;
                ip[i * 4..i * 4 + 4].copy_from_slice(&w.to_le_bytes());
            }
            ip
        }
        _ => return None,
    };
    Some((ip, port))
}

struct SockTable {
    exact: HashMap<Flow, u64>,
    /// (proto, local port) -> [(local ip, inode)]: listeners and unconnected UDP.
    bound: HashMap<(u8, u16), Vec<(Ip, u64)>>,
}

impl SockTable {
    fn load() -> Self {
        let mut t = SockTable { exact: HashMap::new(), bound: HashMap::new() };
        for (file, proto) in [("tcp", PROTO_TCP), ("tcp6", PROTO_TCP), ("udp", PROTO_UDP), ("udp6", PROTO_UDP)] {
            let Ok(text) = fs::read_to_string(format!("/proc/net/{file}")) else { continue };
            for line in text.lines().skip(1) {
                let f: Vec<&str> = line.split_whitespace().collect();
                if f.len() < 10 {
                    continue;
                }
                let (Some((lip, lport)), Some((rip, rport))) = (parse_hex_addr(f[1]), parse_hex_addr(f[2])) else { continue };
                let Ok(inode) = f[9].parse::<u64>() else { continue };
                if inode == 0 {
                    continue; // TIME_WAIT etc.: no owning socket
                }
                t.bound.entry((proto, lport)).or_default().push((lip, inode));
                if rport != 0 {
                    t.exact.insert(Flow { proto, lip, lport, rip, rport }, inode);
                }
            }
        }
        t
    }

    fn inode_for(&self, f: &Flow) -> Option<u64> {
        if let Some(&i) = self.exact.get(f) {
            return Some(i);
        }
        let cands = self.bound.get(&(f.proto, f.lport))?;
        cands.iter().find(|(ip, _)| ip == &f.lip).or_else(|| cands.iter().find(|(ip, _)| is_wildcard(ip))).map(|&(_, i)| i)
    }
}

fn scan_inode_pids() -> HashMap<u64, i32> {
    let mut m = HashMap::new();
    let Ok(procs) = fs::read_dir("/proc") else { return m };
    for p in procs.flatten() {
        let Some(pid) = p.file_name().to_str().and_then(|s| s.parse::<i32>().ok()) else { continue };
        let Ok(fds) = fs::read_dir(format!("/proc/{pid}/fd")) else { continue };
        for fd in fds.flatten() {
            let Ok(target) = fs::read_link(fd.path()) else { continue };
            let Some(s) = target.to_str() else { continue };
            if let Some(n) = s.strip_prefix("socket:[").and_then(|r| r.strip_suffix(']')).and_then(|r| r.parse::<u64>().ok()) {
                m.entry(n).or_insert(pid);
            }
        }
    }
    m
}

fn proc_name(pid: i32) -> String {
    fs::read_to_string(format!("/proc/{pid}/comm")).map(|s| s.trim().to_string()).unwrap_or_else(|_| format!("pid{pid}"))
}

struct Resolver {
    cache: HashMap<Flow, (Option<i32>, Instant)>,
    inode_pid: HashMap<u64, i32>,
    last_fd_scan: Option<Instant>,
}

impl Resolver {
    fn new() -> Self {
        Resolver { cache: HashMap::new(), inode_pid: HashMap::new(), last_fd_scan: None }
    }

    fn ttl(pid: &Option<i32>) -> Duration {
        if pid.is_some() {
            RESOLVE_TTL
        } else {
            NEGATIVE_TTL
        }
    }

    fn resolve_all<'a>(&mut self, flows: impl Iterator<Item = &'a Flow>, now: Instant) {
        let stale: Vec<Flow> = flows
            .filter(|f| match self.cache.get(f) {
                Some((pid, at)) => now.duration_since(*at) > Self::ttl(pid),
                None => true,
            })
            .copied()
            .collect();
        if stale.is_empty() {
            return;
        }
        let table = SockTable::load();
        let inodes: Vec<(Flow, Option<u64>)> = stale.iter().map(|f| (*f, table.inode_for(f))).collect();
        let need_scan = inodes.iter().any(|(_, i)| i.is_some_and(|i| !self.inode_pid.contains_key(&i)))
            && self.last_fd_scan.is_none_or(|t| now.duration_since(t) >= FD_SCAN_MIN_GAP);
        if need_scan {
            self.inode_pid = scan_inode_pids();
            self.last_fd_scan = Some(now);
        }
        for (f, inode) in inodes {
            let pid = inode.and_then(|i| self.inode_pid.get(&i).copied());
            self.cache.insert(f, (pid, now));
        }
        if self.cache.len() > MAX_FLOW_CACHE {
            self.cache.retain(|_, (pid, at)| now.duration_since(*at) <= Self::ttl(pid));
            if self.cache.len() > MAX_FLOW_CACHE {
                self.cache.clear();
            }
        }
    }
}

fn if_name(idx: u32, names: &mut HashMap<u32, String>) -> Option<String> {
    if let Some(n) = names.get(&idx) {
        return Some(n.clone());
    }
    let mut buf = [0 as libc::c_char; libc::IF_NAMESIZE];
    // SAFETY: buf is IF_NAMESIZE bytes as if_indextoname requires.
    let p = unsafe { libc::if_indextoname(idx, buf.as_mut_ptr()) };
    if p.is_null() {
        return None;
    }
    // SAFETY: on success buf holds a NUL-terminated name.
    let n = unsafe { std::ffi::CStr::from_ptr(buf.as_ptr()) }.to_string_lossy().into_owned();
    if names.len() > 1024 {
        names.clear();
    }
    names.insert(idx, n.clone());
    Some(n)
}

fn list_ifaces(include_lo: bool) -> Vec<String> {
    let Ok(d) = fs::read_dir("/sys/class/net") else { return Vec::new() };
    d.flatten().filter_map(|e| e.file_name().into_string().ok()).filter(|n| include_lo || n != "lo").collect()
}

// --- helper process management ---

fn helper_path() -> (String, bool) {
    match std::env::var(HELPER_ENV) {
        Ok(p) if !p.is_empty() => (p, true),
        _ => (DEFAULT_HELPER.to_string(), false),
    }
}

/// The default helper must be a regular file owned by root and not writable by
/// group/other, so an unprivileged process cannot swap what we exec. (A write
/// would also strip its file capability, but refusing is cheaper than reasoning.)
fn check_helper_file(path: &str, trusted_override: bool) -> io::Result<()> {
    let md = fs::metadata(path)?;
    if !md.is_file() {
        return Err(io::Error::new(io::ErrorKind::InvalidInput, "helper is not a regular file"));
    }
    if !trusted_override && (md.uid() != 0 || md.mode() & 0o022 != 0) {
        return Err(io::Error::new(io::ErrorKind::PermissionDenied, "helper must be root-owned and not group/world-writable"));
    }
    Ok(())
}

fn spawn_helper() -> io::Result<Child> {
    let (path, ov) = helper_path();
    check_helper_file(&path, ov)?;
    Command::new(&path).stdin(Stdio::null()).stdout(Stdio::piped()).stderr(Stdio::inherit()).spawn()
}

/// Waits up to `timeout` for the pipe to become readable (or hit EOF/error).
fn wait_readable(fd: i32, timeout: Duration) -> bool {
    let mut p = libc::pollfd { fd, events: libc::POLLIN, revents: 0 };
    // SAFETY: p is a valid pollfd; nfds = 1.
    let r = unsafe { libc::poll(&mut p, 1, timeout.as_millis().min(i32::MAX as u128) as i32) };
    r > 0
}

/// `Read` over the helper's stdout that enforces the per-read timeout.
struct TimedPipe {
    inner: std::process::ChildStdout,
}
impl Read for TimedPipe {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        if !wait_readable(self.inner.as_raw_fd(), READ_TIMEOUT) {
            return Err(io::Error::new(io::ErrorKind::TimedOut, "helper produced nothing for too long"));
        }
        self.inner.read(buf)
    }
}

fn kill_and_reap(mut child: Child) {
    let _ = child.kill();
    let _ = child.wait();
}

/// Starts the helper and a supervising reader thread. `Err` if the helper is
/// missing, untrusted, or fails to confirm it started and confined itself
/// (typically: `setcap cap_net_raw+ep` was never run). Nothing is left running then.
pub fn start<F>(mut on_tick: F) -> io::Result<()>
where
    F: FnMut(TickReport) + Send + 'static,
{
    let mut child = spawn_helper()?;
    let stdout = child.stdout.take().ok_or_else(|| io::Error::other("no stdout"))?;
    let mut pipe = TimedPipe { inner: stdout };

    // Hello must arrive promptly; do the blocking read here so failure is reported to the caller.
    if !wait_readable(pipe.inner.as_raw_fd(), HELLO_TIMEOUT) {
        kill_and_reap(child);
        return Err(io::Error::new(io::ErrorKind::TimedOut, "netcap-helper did not start"));
    }
    if let Err(e) = read_hello(&mut pipe) {
        let status = child.wait().ok();
        return Err(io::Error::other(format!("netcap-helper failed to start ({e:?}, {status:?}); see its stderr above")));
    }

    std::thread::Builder::new().name("netcap".into()).spawn(move || {
        let include_lo = std::env::var_os("SYSMON_NETCAP_LO").is_some();
        let mut resolver = Resolver::new();
        let mut names: HashMap<u32, String> = HashMap::new();
        loop {
            // Pump frames until the stream ends or violates the protocol.
            loop {
                match read_tick(&mut pipe) {
                    Ok((elapsed_ms, recs)) => on_tick(build_report(&mut resolver, &mut names, recs, elapsed_ms, include_lo)),
                    Err(FrameError::Io(e)) => {
                        eprintln!("sysmond: netcap-helper stream ended ({e}); restarting");
                        break;
                    }
                    Err(FrameError::Protocol(why)) => {
                        eprintln!("sysmond: netcap-helper protocol violation ({why}); restarting");
                        break;
                    }
                }
            }
            kill_and_reap(child);
            // Interfaces' lists would go stale while the helper is down.
            on_tick(list_ifaces(include_lo).into_iter().map(|n| (n, Vec::new())).collect());
            // Respawn with backoff; the helper may be mid-upgrade.
            loop {
                std::thread::sleep(RESTART_BACKOFF);
                let attempt = (|| -> io::Result<(Child, TimedPipe)> {
                    let mut c = spawn_helper()?;
                    let out = c.stdout.take().ok_or_else(|| io::Error::other("no stdout"))?;
                    let mut p = TimedPipe { inner: out };
                    if !wait_readable(p.inner.as_raw_fd(), HELLO_TIMEOUT) || read_hello(&mut p).is_err() {
                        kill_and_reap(c);
                        return Err(io::Error::other("helper did not confirm start"));
                    }
                    Ok((c, p))
                })();
                if let Ok((c, p)) = attempt {
                    child = c;
                    pipe = p;
                    break;
                }
            }
        }
    })?;
    Ok(())
}

fn build_report(resolver: &mut Resolver, names: &mut HashMap<u32, String>, recs: Vec<Record>, elapsed_ms: u32, include_lo: bool) -> TickReport {
    let now = Instant::now();
    let elapsed = (elapsed_ms as f64 / 1000.0).max(0.001);
    resolver.resolve_all(recs.iter().map(|r| &r.flow), now);
    let mut per_iface: HashMap<String, HashMap<i32, (u64, u64)>> = list_ifaces(include_lo).into_iter().map(|n| (n, HashMap::new())).collect();
    for r in recs {
        let Some(name) = if_name(r.ifindex, names) else { continue };
        if !include_lo && name == "lo" {
            continue;
        }
        let Some(Some(pid)) = resolver.cache.get(&r.flow).map(|(p, _)| *p) else { continue };
        let e = per_iface.entry(name).or_default().entry(pid).or_insert((0, 0));
        e.0 = e.0.saturating_add(r.sent);
        e.1 = e.1.saturating_add(r.recv);
    }
    per_iface
        .into_iter()
        .map(|(iface, pids)| {
            let samples = pids.into_iter().map(|(pid, (s, r))| (pid, proc_name(pid), s as f64 / 1024.0 / elapsed, r as f64 / 1024.0 / elapsed)).collect();
            (iface, samples)
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn rec_bytes(ifindex: u32, proto: u8, lport: u16, rport: u16, sent: u64, recv: u64) -> Vec<u8> {
        let mut b = vec![0u8; RECORD_LEN];
        b[0..4].copy_from_slice(&ifindex.to_le_bytes());
        b[4] = proto;
        b[8..24].copy_from_slice(&[1; 16]);
        b[24..40].copy_from_slice(&[2; 16]);
        b[40..42].copy_from_slice(&lport.to_le_bytes());
        b[42..44].copy_from_slice(&rport.to_le_bytes());
        b[48..56].copy_from_slice(&sent.to_le_bytes());
        b[56..64].copy_from_slice(&recv.to_le_bytes());
        b
    }
    fn frame(magic: u32, n: u32, ms: u32, recs: &[Vec<u8>]) -> Vec<u8> {
        let mut f = Vec::new();
        f.extend_from_slice(&magic.to_le_bytes());
        f.extend_from_slice(&n.to_le_bytes());
        f.extend_from_slice(&ms.to_le_bytes());
        f.extend_from_slice(&0u32.to_le_bytes());
        for r in recs {
            f.extend_from_slice(r);
        }
        f
    }

    #[test]
    fn decodes_golden_record_matching_helper_encoding() {
        // Same bytes as netcap-helper's wire::golden_bytes test.
        let mut b = vec![0u8; RECORD_LEN];
        b[0] = 2;
        b[4] = 17;
        b[8..24].copy_from_slice(&[1; 16]);
        b[24..40].copy_from_slice(&[2; 16]);
        b[40..44].copy_from_slice(&[0x34, 0x12, 0x78, 0x56]);
        b[48..56].copy_from_slice(&[8, 7, 6, 5, 4, 3, 2, 1]);
        b[56] = 9;
        let r = decode_record(&b).unwrap();
        assert_eq!((r.ifindex, r.flow.proto, r.flow.lport, r.flow.rport, r.sent, r.recv), (2, 17, 0x1234, 0x5678, 0x0102030405060708, 9));
    }

    #[test]
    fn reads_valid_frame() {
        let f = frame(MAGIC_TICK, 2, 1003, &[rec_bytes(2, 6, 80, 5000, 10, 20), rec_bytes(3, 17, 53, 6000, 0, 7)]);
        let (ms, recs) = read_tick(&mut &f[..]).ok().unwrap();
        assert_eq!((ms, recs.len()), (1003, 2));
        assert_eq!(recs[1].recv, 7);
    }

    #[test]
    fn rejects_protocol_violations() {
        let proto = |f: Vec<u8>| matches!(read_tick(&mut &f[..]), Err(FrameError::Protocol(_)));
        assert!(proto(frame(0xdeadbeef, 0, 0, &[])), "bad magic");
        assert!(proto(frame(MAGIC_TICK, MAX_RECORDS + 1, 0, &[])), "count over cap (must fail before allocating)");
        assert!(proto(frame(MAGIC_TICK, u32::MAX, 0, &[])), "huge count");
        let mut bad_proto = rec_bytes(2, 99, 1, 2, 0, 0);
        assert!(proto(frame(MAGIC_TICK, 1, 0, &[bad_proto.clone()])), "unknown protocol");
        bad_proto[4] = 6;
        bad_proto[5] = 1; // reserved byte set
        assert!(proto(frame(MAGIC_TICK, 1, 0, &[bad_proto])), "reserved bytes");
        let mut rsv = frame(MAGIC_TICK, 0, 0, &[]);
        rsv[12] = 1;
        assert!(proto(rsv), "reserved header field");
        // Hello is not a tick.
        assert!(proto(frame(MAGIC_HELLO, 0, 0, &[])));
    }

    #[test]
    fn truncated_stream_is_an_io_error_not_a_panic() {
        let f = frame(MAGIC_TICK, 2, 1000, &[rec_bytes(2, 6, 80, 5000, 10, 20), rec_bytes(3, 17, 53, 6000, 0, 7)]);
        for cut in 0..f.len() {
            assert!(matches!(read_tick(&mut &f[..cut]), Err(FrameError::Io(_))), "cut={cut}");
        }
    }

    #[test]
    fn random_garbage_never_panics_or_overallocates() {
        let mut x: u64 = 0x1234_5678_9abc_def1;
        let mut next = || {
            x ^= x << 13;
            x ^= x >> 7;
            x ^= x << 17;
            x
        };
        for _ in 0..200_000 {
            let len = (next() % 200) as usize;
            let mut buf: Vec<u8> = (0..len).map(|_| next() as u8).collect();
            if len >= 4 && next() % 2 == 0 {
                buf[0..4].copy_from_slice(&MAGIC_TICK.to_le_bytes());
            }
            let _ = read_tick(&mut &buf[..]);
        }
    }

    #[test]
    fn hello_validation() {
        assert!(read_hello(&mut &frame(MAGIC_HELLO, 0, 0, &[])[..]).is_ok());
        assert!(read_hello(&mut &frame(MAGIC_HELLO, 1, 0, &[])[..]).is_err());
        assert!(read_hello(&mut &frame(MAGIC_TICK, 0, 0, &[])[..]).is_err());
    }

    #[test]
    fn hex_addresses_and_wildcards() {
        assert_eq!(parse_hex_addr("0100007F:1F90"), Some((v4(&[127, 0, 0, 1]), 8080)));
        let (ip, port) = parse_hex_addr("00000000000000000000000001000000:0016").unwrap();
        let mut want = [0u8; 16];
        want[15] = 1;
        assert_eq!((ip, port), (want, 22));
        assert!(is_wildcard(&parse_hex_addr("00000000:0050").unwrap().0));
        assert!(is_wildcard(&[0u8; 16]));
        assert!(!is_wildcard(&want));
        assert!(parse_hex_addr("zz:1").is_none() && parse_hex_addr("0100007F").is_none() && parse_hex_addr("0100:1").is_none());
    }

    #[test]
    fn lookup_prefers_exact_then_bound_then_wildcard() {
        let lip = v4(&[10, 0, 0, 1]);
        let flow = Flow { proto: PROTO_TCP, lip, lport: 80, rip: v4(&[9, 9, 9, 9]), rport: 4000 };
        let mut t = SockTable { exact: HashMap::new(), bound: HashMap::new() };
        t.bound.entry((PROTO_TCP, 80)).or_default().push(([0; 16], 7));
        assert_eq!(t.inode_for(&flow), Some(7));
        t.exact.insert(flow, 9);
        assert_eq!(t.inode_for(&flow), Some(9));
        assert_eq!(t.inode_for(&Flow { rport: 4001, ..flow }), Some(7));
        assert_eq!(t.inode_for(&Flow { lport: 81, ..flow }), None);
    }

    #[test]
    fn resolver_cache_is_bounded() {
        let mut r = Resolver::new();
        let now = Instant::now();
        for i in 0..(MAX_FLOW_CACHE + 500) as u32 {
            let f = Flow { proto: PROTO_UDP, lip: [0; 16], lport: (i % 65535) as u16 + 1, rip: v4(&i.to_be_bytes()), rport: 1 };
            r.cache.insert(f, (None, now));
        }
        r.cache.insert(Flow { proto: PROTO_UDP, lip: [9; 16], lport: 1, rip: [0; 16], rport: 1 }, (None, now));
        // Trigger the eviction path with an unresolvable flow.
        let f = Flow { proto: PROTO_UDP, lip: [7; 16], lport: 1, rip: [0; 16], rport: 1 };
        r.resolve_all(std::iter::once(&f), now);
        assert!(r.cache.len() <= MAX_FLOW_CACHE, "cache must be capped, got {}", r.cache.len());
    }

    #[test]
    fn untrusted_helper_path_is_rejected() {
        let dir = std::env::temp_dir().join(format!("netcap-path-test-{}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        let f = dir.join("h");
        fs::write(&f, b"x").unwrap();
        // Owned by us (not root): rejected unless explicitly overridden.
        assert!(check_helper_file(f.to_str().unwrap(), false).is_err());
        assert!(check_helper_file(f.to_str().unwrap(), true).is_ok());
        assert!(check_helper_file(dir.to_str().unwrap(), true).is_err(), "directories are not helpers");
        assert!(check_helper_file("/nonexistent/helper", true).is_err());
        let _ = fs::remove_dir_all(&dir);
    }
}
