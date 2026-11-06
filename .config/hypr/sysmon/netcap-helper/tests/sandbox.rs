//! Proves the seccomp allowlist is actually enforced, not just well-formed:
//! each forbidden syscall runs in a forked child that has called
//! `lock_down`, and must die from SIGSYS; each allowed operation must survive.
//! Single #[test] on purpose: fork() in a multithreaded harness is only safe
//! when no other thread can hold the allocator lock.

use netcap_helper::sandbox;
use std::ffi::CString;
use std::sync::Mutex;

/// fork() is only safe while no other test thread can hold the allocator lock.
static LOCK: Mutex<()> = Mutex::new(());

fn udp_socket() -> i32 {
    // Like the helper, seed hashing *before* sealing: the allowlist has no getrandom.
    let _ = std::collections::hash_map::RandomState::new();
    // Stand-in for the AF_PACKET socket (which needs CAP_NET_RAW to create).
    // SAFETY: plain syscalls.
    unsafe {
        let fd = libc::socket(libc::AF_INET, libc::SOCK_DGRAM | libc::SOCK_NONBLOCK, 0);
        assert!(fd >= 3);
        fd
    }
}

/// Forks, locks the child down with `fd` as the capture socket, runs `body`,
/// and returns (killed_by_signal, exit_code).
fn run_confined(body: fn(i32)) -> (Option<i32>, Option<i32>) {
    // SAFETY: the child only calls libc/sandbox functions then _exit.
    unsafe {
        let fd = udp_socket();
        let pid = libc::fork();
        assert!(pid >= 0);
        if pid == 0 {
            if sandbox::lock_down(fd).is_err() {
                libc::_exit(111);
            }
            body(fd);
            libc::_exit(0);
        }
        let mut status = 0;
        assert_eq!(libc::waitpid(pid, &mut status, 0), pid);
        libc::close(fd);
        if libc::WIFSIGNALED(status) {
            (Some(libc::WTERMSIG(status)), None)
        } else {
            (None, Some(libc::WEXITSTATUS(status)))
        }
    }
}

#[test]
fn seccomp_is_enforced() {
    let _g = LOCK.lock().unwrap();
    let forbidden: Vec<(&str, fn(i32))> = vec![
        ("openat", |_| unsafe {
            let p = CString::new("/etc/passwd").unwrap();
            libc::open(p.as_ptr(), libc::O_RDONLY);
        }),
        ("socket", |_| unsafe {
            libc::socket(libc::AF_INET, libc::SOCK_DGRAM, 0);
        }),
        ("sendto (packet injection)", |fd| unsafe {
            let b = [0u8; 4];
            libc::sendto(fd, b.as_ptr() as *const _, 4, 0, std::ptr::null(), 0);
        }),
        ("sendmsg", |fd| unsafe {
            let mut m: libc::msghdr = std::mem::zeroed();
            libc::sendmsg(fd, &mut m, 0);
        }),
        ("sendmmsg", |fd| unsafe {
            libc::syscall(libc::SYS_sendmmsg, fd, 0usize, 0u32, 0u32);
        }),
        ("connect", |fd| unsafe {
            let a: libc::sockaddr_in = std::mem::zeroed();
            libc::connect(fd, &a as *const _ as *const libc::sockaddr, std::mem::size_of::<libc::sockaddr_in>() as u32);
        }),
        ("bind", |fd| unsafe {
            let a: libc::sockaddr_in = std::mem::zeroed();
            libc::bind(fd, &a as *const _ as *const libc::sockaddr, std::mem::size_of::<libc::sockaddr_in>() as u32);
        }),
        ("setsockopt", |fd| unsafe {
            let v: libc::c_int = 1;
            libc::setsockopt(fd, libc::SOL_SOCKET, libc::SO_BROADCAST, &v as *const _ as *const _, 4);
        }),
        ("execve", |_| unsafe {
            let p = CString::new("/bin/true").unwrap();
            let argv = [p.as_ptr(), std::ptr::null()];
            libc::execv(p.as_ptr(), argv.as_ptr());
        }),
        ("ptrace", |_| unsafe {
            libc::ptrace(libc::PTRACE_TRACEME, 0, 0, 0);
        }),
        ("mprotect", |_| unsafe {
            let p = libc::mmap(std::ptr::null_mut(), 4096, libc::PROT_READ | libc::PROT_WRITE, libc::MAP_PRIVATE | libc::MAP_ANONYMOUS, -1, 0);
            libc::mprotect(p, 4096, libc::PROT_READ | libc::PROT_EXEC);
        }),
        ("mmap PROT_EXEC", |_| unsafe {
            libc::mmap(std::ptr::null_mut(), 4096, libc::PROT_READ | libc::PROT_EXEC, libc::MAP_PRIVATE | libc::MAP_ANONYMOUS, -1, 0);
        }),
        ("write to fd 2 (only fd 1 allowed)", |_| unsafe {
            libc::write(2, b"x".as_ptr() as *const _, 1);
        }),
        ("write to the capture socket", |fd| unsafe {
            libc::write(fd, b"x".as_ptr() as *const _, 1);
        }),
        ("read", |fd| unsafe {
            let mut b = [0u8; 1];
            libc::read(fd, b.as_mut_ptr() as *mut _, 1);
        }),
        ("recvfrom on a different fd", |fd| unsafe {
            let mut b = [0u8; 1];
            libc::recvfrom(fd + 1, b.as_mut_ptr() as *mut _, 1, 0, std::ptr::null_mut(), std::ptr::null_mut());
        }),
        ("kill self", |_| unsafe {
            libc::kill(libc::getpid(), 0);
        }),
        ("tgkill", |_| unsafe {
            libc::syscall(libc::SYS_tgkill, libc::getpid(), libc::getpid(), 0);
        }),
        ("prctl (re-enable dumpable)", |_| unsafe {
            libc::prctl(libc::PR_SET_DUMPABLE, 1, 0, 0, 0);
        }),
        ("capset", |_| unsafe {
            libc::syscall(libc::SYS_capset, 0usize, 0usize);
        }),
        ("fork/clone", |_| unsafe {
            libc::fork();
        }),
        ("unshare", |_| unsafe {
            libc::unshare(libc::CLONE_NEWNET);
        }),
        ("setuid", |_| unsafe {
            libc::setuid(0);
        }),
        ("io_uring_setup", |_| unsafe {
            libc::syscall(libc::SYS_io_uring_setup, 8u32, 0usize);
        }),
        ("bpf", |_| unsafe {
            libc::syscall(libc::SYS_bpf, 0u32, 0usize, 0u32);
        }),
    ];
    let mut failures = Vec::new();
    for (name, body) in forbidden {
        let (sig, code) = run_confined(body);
        if sig != Some(libc::SIGSYS) {
            failures.push(format!("{name}: expected SIGSYS, got signal={sig:?} exit={code:?}"));
        }
    }
    assert!(failures.is_empty(), "seccomp holes:\n{}", failures.join("\n"));

    let allowed: Vec<(&str, fn(i32))> = vec![
        ("zero-length write to fd 1", |_| unsafe {
            libc::write(1, b"".as_ptr() as *const _, 0);
        }),
        ("recvfrom on the capture socket", |fd| unsafe {
            let mut b = [0u8; 8];
            let mut a: libc::sockaddr_storage = std::mem::zeroed();
            let mut l = std::mem::size_of::<libc::sockaddr_storage>() as u32;
            let r = libc::recvfrom(fd, b.as_mut_ptr() as *mut _, 8, libc::MSG_TRUNC, &mut a as *mut _ as *mut libc::sockaddr, &mut l);
            assert!(r < 0); // nothing queued: EAGAIN, but not killed
        }),
        ("heap growth + free (brk/mmap/munmap/mremap)", |_| {
            let mut v: Vec<u8> = Vec::new();
            for i in 0..(8 << 20) {
                v.push(i as u8);
            }
            let m: std::collections::HashMap<u32, u32> = (0..50_000).map(|i| (i, i)).collect();
            assert_eq!(v.len() + m.len(), (8 << 20) + 50_000);
        }),
        ("mprotect without PROT_EXEC", |_| unsafe {
            let p = libc::mmap(std::ptr::null_mut(), 4096, libc::PROT_READ | libc::PROT_WRITE, libc::MAP_PRIVATE | libc::MAP_ANONYMOUS, -1, 0);
            assert_ne!(p, libc::MAP_FAILED);
            assert_eq!(libc::mprotect(p, 4096, libc::PROT_READ), 0);
        }),
        ("Instant::now (clock_gettime)", |_| {
            let _ = std::time::Instant::now().elapsed();
        }),
    ];
    for (name, body) in allowed {
        let (sig, code) = run_confined(body);
        assert_eq!((sig, code), (None, Some(0)), "allowed op '{name}' must survive");
    }
}

#[test]
fn caps_are_dropped_then_verified() {
    // Runs in the same serialized flow as the fork test? No: it does not fork,
    // but it must not run concurrently with a fork. Take the lock.
    let _g = LOCK.lock().unwrap();
    // The login session may carry a non-empty *inheritable* set (CapInh), which
    // is exactly why verification exists: it must catch it, and drop_all_caps
    // must fix it.
    sandbox::drop_all_caps().unwrap();
    sandbox::verify_no_caps().unwrap();
}
