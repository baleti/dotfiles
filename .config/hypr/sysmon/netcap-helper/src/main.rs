//! netcap-helper entry point. See lib.rs for the trust model.
//!
//! Output: one-way stream on stdout (must be a pipe or socket). Exit codes:
//! 1 = refused to start (not enough privilege, sandbox failed, bad stdout);
//! 0 = reader went away.

use netcap_helper::packet::{parse, Flow};
use netcap_helper::sandbox;
use netcap_helper::wire::{self, Record};
use std::collections::HashMap;
use std::io;
use std::time::{Duration, Instant};

const SNAP: usize = 64; // enough for IPv6 (40) + TCP/UDP ports
const TICK: Duration = Duration::from_millis(1000);

fn die(msg: &str) -> ! {
    eprintln!("netcap-helper: {msg}");
    // SAFETY: _exit is async-signal-safe and always valid.
    unsafe { libc::_exit(1) }
}

/// stdout must be a FIFO or socket: refuse to spray binary at a terminal/file.
fn require_pipe_stdout() {
    let mut st: libc::stat = unsafe { std::mem::zeroed() };
    // SAFETY: st is a valid out-pointer.
    if unsafe { libc::fstat(1, &mut st) } != 0 {
        die("cannot stat stdout");
    }
    let kind = st.st_mode & libc::S_IFMT;
    if kind != libc::S_IFIFO && kind != libc::S_IFSOCK {
        die("stdout must be a pipe or socket");
    }
}

fn open_socket() -> io::Result<i32> {
    let proto = i32::from((libc::ETH_P_ALL as u16).to_be());
    // SAFETY: plain syscalls; pointers are to live stack values of the right size.
    unsafe {
        let fd = libc::socket(libc::AF_PACKET, libc::SOCK_DGRAM | libc::SOCK_CLOEXEC, proto);
        if fd < 0 {
            return Err(io::Error::last_os_error());
        }
        let rcvbuf: libc::c_int = 4 << 20;
        let tv = libc::timeval { tv_sec: 0, tv_usec: 200_000 };
        let r1 = libc::setsockopt(fd, libc::SOL_SOCKET, libc::SO_RCVBUF, &rcvbuf as *const _ as *const _, std::mem::size_of_val(&rcvbuf) as u32);
        let r2 = libc::setsockopt(fd, libc::SOL_SOCKET, libc::SO_RCVTIMEO, &tv as *const _ as *const _, std::mem::size_of_val(&tv) as u32);
        if r1 != 0 || r2 != 0 {
            return Err(io::Error::last_os_error());
        }
        Ok(fd)
    }
}

/// Writes all of `buf` to fd 1. Exits quietly when the reader is gone.
fn write_all(mut buf: &[u8]) {
    while !buf.is_empty() {
        // SAFETY: buf is a valid readable slice.
        let n = unsafe { libc::write(1, buf.as_ptr() as *const _, buf.len()) };
        if n < 0 {
            let e = io::Error::last_os_error();
            if e.kind() == io::ErrorKind::Interrupted {
                continue;
            }
            // EPIPE (sysmond exited/restarted) or anything else: stop.
            // SAFETY: _exit is always valid.
            unsafe { libc::_exit(0) }
        }
        buf = &buf[n as usize..];
    }
}

fn main() {
    if std::env::args_os().len() > 1 {
        die("takes no arguments");
    }
    require_pipe_stdout();
    if let Err(e) = sandbox::harden_process() {
        die(&format!("hardening failed: {e}"));
    }
    let sock = match open_socket() {
        Ok(fd) => fd,
        Err(e) => die(&format!("cannot open packet socket ({e}); is cap_net_raw set on this binary?")),
    };
    if sock < 3 {
        die("socket landed on a stdio descriptor");
    }

    // Pre-size everything that would otherwise allocate in the hot path. This
    // also seeds the HashMap's RandomState: the sandbox has no getrandom, so
    // any HashMap created after lock_down() would kill the process.
    let mut acc: HashMap<(u32, Flow), (u64, u64)> = HashMap::with_capacity(4096);
    let mut out: Vec<u8> = Vec::with_capacity(wire::HEADER_LEN + 4096 * wire::RECORD_LEN);

    if let Err(e) = sandbox::lock_down(sock) {
        die(&format!("sandbox failed, refusing to run: {e}"));
    }

    write_all(&wire::encode_header(wire::MAGIC_HELLO, 0, 0)); // healthy + confined

    let mut buf = [0u8; SNAP];
    let mut tick_start = Instant::now();
    loop {
        let mut sll: libc::sockaddr_ll = unsafe { std::mem::zeroed() };
        let mut slen = std::mem::size_of::<libc::sockaddr_ll>() as libc::socklen_t;
        // SAFETY: buf/sll/slen are valid for the lengths passed. MSG_TRUNC makes
        // the return value the real packet length even though only SNAP bytes
        // are copied.
        let n = unsafe { libc::recvfrom(sock, buf.as_mut_ptr() as *mut _, SNAP, libc::MSG_TRUNC, &mut sll as *mut _ as *mut libc::sockaddr, &mut slen) };
        if n >= 0 {
            let real_len = n as u64;
            let got = (n as usize).min(SNAP);
            let outgoing = sll.sll_pkttype == libc::PACKET_OUTGOING;
            let ifindex = sll.sll_ifindex;
            if ifindex > 0 {
                if let Some(flow) = parse(&buf[..got], u16::from_be(sll.sll_protocol), outgoing) {
                    let key = (ifindex as u32, flow);
                    if acc.len() < wire::MAX_RECORDS as usize || acc.contains_key(&key) {
                        let e = acc.entry(key).or_insert((0, 0));
                        if outgoing {
                            e.0 = e.0.saturating_add(real_len);
                        } else {
                            e.1 = e.1.saturating_add(real_len);
                        }
                    }
                }
            }
        } else {
            match io::Error::last_os_error().kind() {
                io::ErrorKind::WouldBlock | io::ErrorKind::Interrupted | io::ErrorKind::TimedOut => {}
                _ => die("capture socket failed"),
            }
        }

        let now = Instant::now();
        let since = now.duration_since(tick_start);
        if since < TICK {
            continue;
        }
        tick_start = now;

        out.clear();
        let n_rec = acc.len().min(wire::MAX_RECORDS as usize) as u32;
        out.extend_from_slice(&wire::encode_header(wire::MAGIC_TICK, n_rec, since.as_millis().min(u128::from(u32::MAX)) as u32));
        for ((ifindex, f), (sent, recv)) in acc.drain().take(n_rec as usize) {
            out.extend_from_slice(&wire::encode_record(&Record { ifindex, proto: f.proto, lip: f.lip, lport: f.lport, rip: f.rip, rport: f.rport, sent, recv }));
        }
        acc.shrink_to(4096);
        write_all(&out);
    }
}
