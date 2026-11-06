//! End-to-end: runs the real binary inside an unprivileged user+net namespace
//! (full capabilities there, no host impact), generates known loopback traffic,
//! and checks the byte stream, plus the helper's own confinement as seen from
//! /proc. Skipped (with a message) if user namespaces are unavailable.

use netcap_helper::wire::{HEADER_LEN, MAGIC_HELLO, MAGIC_TICK, RECORD_LEN};
use std::io::Read;
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

const HELPER: &str = env!("CARGO_BIN_EXE_netcap-helper");

fn userns_ok() -> bool {
    Command::new("unshare").args(["-rn", "true"]).status().map(|s| s.success()).unwrap_or(false)
}

fn u32le(b: &[u8]) -> u32 {
    u32::from_le_bytes(b[..4].try_into().unwrap())
}
fn u64le(b: &[u8]) -> u64 {
    u64::from_le_bytes(b[..8].try_into().unwrap())
}

#[test]
fn captures_udp_and_is_confined() {
    if !userns_ok() {
        eprintln!("SKIP: unprivileged user namespaces unavailable");
        return;
    }
    // Inside the namespace: lo up, background traffic generator, then exec the
    // helper (same pid, so /proc/<pid> inspection works). 300 x 1000-byte UDP
    // datagrams 127.0.0.1:40000 -> :5555 (28 bytes of IP+UDP header each).
    let script = format!(
        r#"ip link set lo up
python3 -I -c '
import socket,time
time.sleep(1.2)
r=socket.socket(socket.AF_INET,socket.SOCK_DGRAM); r.bind(("127.0.0.1",5555))
s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM); s.bind(("127.0.0.1",40000))
for _ in range(300): s.sendto(b"x"*1000,("127.0.0.1",5555))
' &
SYSMON_UNUSED=1 exec {HELPER}"#
    );
    let mut child = Command::new("unshare").args(["-rn", "sh", "-c", &script]).stdout(Stdio::piped()).stderr(Stdio::piped()).spawn().unwrap();
    let pid = child.id();
    let mut out = child.stdout.take().unwrap();

    // HELLO first.
    let mut hdr = [0u8; HEADER_LEN];
    out.read_exact(&mut hdr).expect("helper produced no hello (did the sandbox fail?)");
    assert_eq!(u32le(&hdr[0..4]), MAGIC_HELLO);
    assert_eq!(u32le(&hdr[4..8]), 0);

    // Confinement as observed from outside, after the hello.
    let status = std::fs::read_to_string(format!("/proc/{pid}/status")).unwrap();
    let field = |k: &str| status.lines().find(|l| l.starts_with(k)).map(|l| l[k.len()..].trim().to_string()).unwrap_or_default();
    assert!(field("CapEff:").chars().all(|c| c == '0'), "CapEff not empty: {}", field("CapEff:"));
    assert!(field("CapPrm:").chars().all(|c| c == '0'), "CapPrm not empty");
    assert!(field("CapInh:").chars().all(|c| c == '0'), "CapInh not empty");
    assert_eq!(field("NoNewPrivs:"), "1");
    assert_eq!(field("Seccomp:"), "2", "seccomp filter not active");
    assert!(std::fs::read(format!("/proc/{pid}/mem")).is_err() || std::fs::File::open(format!("/proc/{pid}/environ")).and_then(|mut f| f.read(&mut [0u8; 1])).is_err(), "process should not be dumpable");

    // Collect ~4 ticks, summing the two directions of the UDP flow on port 5555.
    let (mut recv_to_5555, mut sent_from_40000) = (0u64, 0u64);
    let deadline = Instant::now() + Duration::from_secs(6);
    let mut ticks = 0;
    while Instant::now() < deadline && ticks < 5 {
        let mut hdr = [0u8; HEADER_LEN];
        out.read_exact(&mut hdr).unwrap();
        assert_eq!(u32le(&hdr[0..4]), MAGIC_TICK);
        let n = u32le(&hdr[4..8]) as usize;
        assert!(n <= 20_000);
        let mut body = vec![0u8; n * RECORD_LEN];
        out.read_exact(&mut body).unwrap();
        for rec in body.chunks_exact(RECORD_LEN) {
            assert!(rec[5..8].iter().all(|&b| b == 0) && rec[44..48].iter().all(|&b| b == 0), "reserved bytes must be zero");
            let proto = rec[4];
            let lport = u16::from_le_bytes([rec[40], rec[41]]);
            let (sent, recv) = (u64le(&rec[48..56]), u64le(&rec[56..64]));
            if proto == 17 && lport == 5555 {
                recv_to_5555 += recv;
                assert_eq!(sent, 0, "receiver socket never sends");
            }
            if proto == 17 && lport == 40000 {
                sent_from_40000 += sent;
            }
        }
        ticks += 1;
    }
    let want = 300 * (1000 + 28);
    assert_eq!(recv_to_5555, want, "receiver-side byte count");
    assert_eq!(sent_from_40000, want, "sender-side byte count");

    // Reader going away must stop the helper (EPIPE), not leave it running.
    drop(out);
    let t0 = Instant::now();
    loop {
        if let Some(st) = child.try_wait().unwrap() {
            assert!(st.success() || st.code() == Some(0), "unexpected exit: {st:?}");
            break;
        }
        assert!(t0.elapsed() < Duration::from_secs(5), "helper did not exit after its reader closed");
        std::thread::sleep(Duration::from_millis(50));
    }
}

#[test]
fn refuses_without_privilege_and_emits_nothing() {
    // No cap_net_raw and not in a namespace: socket(AF_PACKET) must fail and
    // the helper must exit 1 without writing a single byte.
    if unsafe { libc::geteuid() } == 0 {
        eprintln!("SKIP: running as root");
        return;
    }
    let mut c = Command::new(HELPER).stdout(Stdio::piped()).stderr(Stdio::piped()).spawn().unwrap();
    let mut buf = Vec::new();
    c.stdout.take().unwrap().read_to_end(&mut buf).unwrap();
    let st = c.wait().unwrap();
    assert_eq!(st.code(), Some(1));
    assert!(buf.is_empty(), "must not emit data when it cannot confine itself");
}

#[test]
fn refuses_bad_invocations() {
    // Arguments are rejected.
    let st = Command::new(HELPER).arg("--foo").stdout(Stdio::piped()).stderr(Stdio::null()).status().unwrap();
    assert_eq!(st.code(), Some(1));
    // stdout that is a regular file (or tty) is rejected before anything else.
    let f = std::fs::File::create(std::env::temp_dir().join("netcap-helper-test-out")).unwrap();
    let st = Command::new(HELPER).stdout(Stdio::from(f)).stderr(Stdio::null()).status().unwrap();
    assert_eq!(st.code(), Some(1));
    let _ = std::fs::remove_file(std::env::temp_dir().join("netcap-helper-test-out"));
}

/// Flow flood: 25k distinct flows in one tick must neither crash the helper
/// (growth under seccomp) nor exceed the per-frame record cap.
#[test]
fn flow_flood_is_bounded_and_survives_seccomp() {
    if !userns_ok() {
        eprintln!("SKIP: unprivileged user namespaces unavailable");
        return;
    }
    let script = format!(
        r#"ip link set lo up
python3 -I -c '
import socket,time
time.sleep(1.3)
s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM); s.bind(("127.0.0.1",41000))
for i in range(25000): s.sendto(b"y"*10,("127.0.0.1",1024+i))
' &
exec {HELPER}"#
    );
    let mut child = Command::new("unshare").args(["-rn", "sh", "-c", &script]).stdout(Stdio::piped()).stderr(Stdio::piped()).spawn().unwrap();
    let mut out = child.stdout.take().unwrap();
    let mut hdr = [0u8; HEADER_LEN];
    out.read_exact(&mut hdr).unwrap();
    let mut max_records = 0usize;
    for _ in 0..5 {
        out.read_exact(&mut hdr).expect("helper died during flood (seccomp kill?)");
        assert_eq!(u32le(&hdr[0..4]), MAGIC_TICK);
        let n = u32le(&hdr[4..8]) as usize;
        assert!(n <= 20_000, "frame exceeds MAX_RECORDS: {n}");
        let mut body = vec![0u8; n * RECORD_LEN];
        out.read_exact(&mut body).unwrap();
        max_records = max_records.max(n);
    }
    assert!(max_records > 5_000, "flood should have produced many records, got {max_records}");
    assert!(child.try_wait().unwrap().is_none(), "helper exited unexpectedly");
    drop(out);
    let _ = child.wait();
}
