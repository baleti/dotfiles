//! Self-confinement, applied after the AF_PACKET socket is open and before any
//! packet data is touched. Fails closed: any error here means the caller must
//! exit without emitting anything.
//!
//! Layers (each independently limits a compromised parser):
//!  1. RLIMIT_CORE=0 and PR_SET_DUMPABLE=0: no core dumps, and same-user
//!     processes cannot ptrace us or read /proc/<pid>/{mem,fd} to hijack the
//!     raw socket.
//!  2. Every capability dropped (capset to zero, ambient cleared) and then
//!     *verified* from /proc/self/status. CAP_NET_RAW is needed only for
//!     socket(2); an open fd keeps working without it.
//!  3. no_new_privs, then a seccomp-bpf allowlist (default action: kill the
//!     process). Notably absent: sendto/sendmsg (cannot inject packets),
//!     open/openat, socket/connect/bind, execve, ptrace, mprotect, setsockopt,
//!     kill/tgkill. `write` is only allowed on fd 1, `recvfrom` only on the
//!     capture socket, and `mmap`/`mprotect` never with PROT_EXEC.

use std::io;

#[cfg(target_arch = "x86_64")]
const AUDIT_ARCH: u32 = 0xC000_003E; // AUDIT_ARCH_X86_64
#[cfg(target_arch = "aarch64")]
const AUDIT_ARCH: u32 = 0xC000_00B7; // AUDIT_ARCH_AARCH64
#[cfg(not(any(target_arch = "x86_64", target_arch = "aarch64")))]
compile_error!("netcap-helper's seccomp filter only supports x86_64 and aarch64");

const SECCOMP_RET_KILL_PROCESS: u32 = 0x8000_0000;
const SECCOMP_RET_ALLOW: u32 = 0x7fff_0000;

// Classic BPF opcodes (linux/bpf_common.h), spelled out to avoid depending on
// which of them the libc crate happens to export.
const BPF_LD_W_ABS: u16 = 0x20; // BPF_LD | BPF_W | BPF_ABS
const BPF_JEQ_K: u16 = 0x15; // BPF_JMP | BPF_JEQ | BPF_K
const BPF_JSET_K: u16 = 0x45; // BPF_JMP | BPF_JSET | BPF_K
const BPF_RET_K: u16 = 0x06; // BPF_RET | BPF_K

// struct seccomp_data { int nr; __u32 arch; __u64 ip; __u64 args[6]; }
const OFF_NR: u32 = 0;
const OFF_ARCH: u32 = 4;
const fn off_arg(i: u32) -> u32 {
    16 + 8 * i // low 32 bits of arg i (little-endian)
}

fn stmt(code: u16, k: u32) -> libc::sock_filter {
    libc::sock_filter { code, jt: 0, jf: 0, k }
}
fn jump(code: u16, k: u32, jt: u8, jf: u8) -> libc::sock_filter {
    libc::sock_filter { code, jt, jf, k }
}

/// Syscalls allowed unconditionally: allocator, clock, exit. No entropy source:
/// every HashMap (and its RandomState seed) must be created before `lock_down`.
fn plain_allowed() -> Vec<u32> {
    [
        libc::SYS_brk,
        libc::SYS_munmap,
        libc::SYS_mremap,
        libc::SYS_madvise,
        libc::SYS_clock_gettime,
        libc::SYS_rt_sigreturn,
        libc::SYS_exit_group,
    ]
    .iter()
    .map(|&n| n as u32)
    .collect()
}

/// Builds the allowlist program. Public so tests can inspect/serialize it.
pub fn build_filter(sock_fd: u32) -> Vec<libc::sock_filter> {
    let mut f = vec![
        // Wrong architecture (e.g. 32-bit compat syscalls) => kill.
        stmt(BPF_LD_W_ABS, OFF_ARCH),
        jump(BPF_JEQ_K, AUDIT_ARCH, 1, 0),
        stmt(BPF_RET_K, SECCOMP_RET_KILL_PROCESS),
        stmt(BPF_LD_W_ABS, OFF_NR),
    ];
    for nr in plain_allowed() {
        f.push(jump(BPF_JEQ_K, nr, 0, 1));
        f.push(stmt(BPF_RET_K, SECCOMP_RET_ALLOW));
    }
    // Argument-restricted rules. On a name match they ALWAYS return (allow or
    // kill), so the accumulator clobbered by the arg load is never reused.
    //   write(fd == 1, ...)
    f.push(jump(BPF_JEQ_K, libc::SYS_write as u32, 0, 4));
    f.push(stmt(BPF_LD_W_ABS, off_arg(0)));
    f.push(jump(BPF_JEQ_K, 1, 0, 1));
    f.push(stmt(BPF_RET_K, SECCOMP_RET_ALLOW));
    f.push(stmt(BPF_RET_K, SECCOMP_RET_KILL_PROCESS));
    //   recvfrom(fd == capture socket, ...)
    f.push(jump(BPF_JEQ_K, libc::SYS_recvfrom as u32, 0, 4));
    f.push(stmt(BPF_LD_W_ABS, off_arg(0)));
    f.push(jump(BPF_JEQ_K, sock_fd, 0, 1));
    f.push(stmt(BPF_RET_K, SECCOMP_RET_ALLOW));
    f.push(stmt(BPF_RET_K, SECCOMP_RET_KILL_PROCESS));
    //   mmap(..., prot without PROT_EXEC, ...)
    f.push(jump(BPF_JEQ_K, libc::SYS_mmap as u32, 0, 4));
    f.push(stmt(BPF_LD_W_ABS, off_arg(2)));
    f.push(jump(BPF_JSET_K, libc::PROT_EXEC as u32, 1, 0));
    f.push(stmt(BPF_RET_K, SECCOMP_RET_ALLOW));
    f.push(stmt(BPF_RET_K, SECCOMP_RET_KILL_PROCESS));
    //   mprotect(..., prot without PROT_EXEC, ...): glibc grows non-main-thread
    //   arenas this way; refusing PROT_EXEC keeps memory W^X.
    f.push(jump(BPF_JEQ_K, libc::SYS_mprotect as u32, 0, 4));
    f.push(stmt(BPF_LD_W_ABS, off_arg(2)));
    f.push(jump(BPF_JSET_K, libc::PROT_EXEC as u32, 1, 0));
    f.push(stmt(BPF_RET_K, SECCOMP_RET_ALLOW));
    f.push(stmt(BPF_RET_K, SECCOMP_RET_KILL_PROCESS));
    // Everything else.
    f.push(stmt(BPF_RET_K, SECCOMP_RET_KILL_PROCESS));
    f
}

fn check(ret: libc::c_long) -> io::Result<()> {
    if ret < 0 {
        Err(io::Error::last_os_error())
    } else {
        Ok(())
    }
}

/// Pre-socket hardening: no cores, not dumpable, no inherited descriptors.
pub fn harden_process() -> io::Result<()> {
    let zero = libc::rlimit { rlim_cur: 0, rlim_max: 0 };
    // SAFETY: plain syscalls with valid pointers to initialized stack data.
    unsafe {
        check(libc::setrlimit(libc::RLIMIT_CORE, &zero) as libc::c_long)?;
        check(libc::prctl(libc::PR_SET_DUMPABLE, 0, 0, 0, 0) as libc::c_long)?;
        // Close everything above stderr (kernel >= 5.9). Best effort: a
        // launcher that leaked descriptors is not trusted, but failing hard on
        // older kernels would just disable the feature.
        let _ = libc::syscall(libc::SYS_close_range, 3u32, u32::MAX, 0u32);
    }
    Ok(())
}

#[repr(C)]
struct CapHeader {
    version: u32,
    pid: i32,
}
#[repr(C)]
#[derive(Clone, Copy)]
struct CapData {
    effective: u32,
    permitted: u32,
    inheritable: u32,
}
const LINUX_CAPABILITY_VERSION_3: u32 = 0x2008_0522;

/// Drops every capability from all sets and clears the ambient set.
pub fn drop_all_caps() -> io::Result<()> {
    let hdr = CapHeader { version: LINUX_CAPABILITY_VERSION_3, pid: 0 };
    let data = [CapData { effective: 0, permitted: 0, inheritable: 0 }; 2];
    // SAFETY: hdr/data are valid, correctly laid-out (repr(C)) for capset(2) v3.
    unsafe {
        check(libc::syscall(libc::SYS_capset, &hdr as *const CapHeader, data.as_ptr()))?;
        // PR_CAP_AMBIENT=47, PR_CAP_AMBIENT_CLEAR_ALL=4 (already empty unless the
        // launcher set it; clear regardless). EINVAL on pre-4.3 kernels is fine.
        let _ = libc::prctl(47, 4, 0, 0, 0);
    }
    Ok(())
}

/// Reads the *calling thread's* status (capabilities are per-thread; plain
/// /proc/self/status would report the main thread) and fails unless every
/// capability set is empty.
/// (Bounding set is not checked: with no_new_privs and exec forbidden by
/// seccomp it cannot be used to regain anything.)
pub fn verify_no_caps() -> io::Result<()> {
    let status = std::fs::read_to_string("/proc/thread-self/status").or_else(|_| std::fs::read_to_string("/proc/self/status"))?;
    let mut seen = 0;
    for line in status.lines() {
        for key in ["CapInh:", "CapPrm:", "CapEff:", "CapAmb:"] {
            if let Some(v) = line.strip_prefix(key) {
                seen += 1;
                if v.trim().trim_start_matches('0') != "" {
                    return Err(io::Error::new(io::ErrorKind::PermissionDenied, format!("{key} still set: {}", v.trim())));
                }
            }
        }
    }
    // CapAmb is absent on kernels < 4.3; the other three must be present.
    if seen < 3 {
        return Err(io::Error::new(io::ErrorKind::InvalidData, "could not read capability sets"));
    }
    Ok(())
}

/// Sets no_new_privs and installs the seccomp allowlist. Irreversible.
pub fn install_seccomp(sock_fd: i32) -> io::Result<()> {
    if sock_fd < 3 {
        return Err(io::Error::new(io::ErrorKind::InvalidInput, "capture socket must not be a stdio descriptor"));
    }
    let filter = build_filter(sock_fd as u32);
    let prog = libc::sock_fprog { len: filter.len() as u16, filter: filter.as_ptr() as *mut libc::sock_filter };
    // SAFETY: `prog` points at `filter`, which outlives both calls.
    unsafe {
        check(libc::prctl(libc::PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) as libc::c_long)?;
        check(libc::prctl(libc::PR_SET_SECCOMP, libc::SECCOMP_MODE_FILTER, &prog as *const libc::sock_fprog) as libc::c_long)?;
    }
    Ok(())
}

/// Full confinement, in the only safe order: caps gone and verified, then
/// seccomp (which forbids the /proc read the verification needs).
pub fn lock_down(sock_fd: i32) -> io::Result<()> {
    drop_all_caps()?;
    verify_no_caps()?;
    install_seccomp(sock_fd)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn filter_shape_is_sane() {
        let f = build_filter(7);
        assert!(f.len() < 100, "classic BPF programs are limited to 4096 insns; ours should be tiny");
        // Last instruction must be the default-deny.
        let last = f.last().unwrap();
        assert_eq!((last.code, last.k), (BPF_RET_K, SECCOMP_RET_KILL_PROCESS));
        // Every jump target stays inside the program, and never lands past the end.
        for (i, ins) in f.iter().enumerate() {
            if ins.code == BPF_JEQ_K || ins.code == BPF_JSET_K {
                assert!(i + 1 + usize::from(ins.jt) < f.len(), "jt out of range at {i}");
                assert!(i + 1 + usize::from(ins.jf) < f.len(), "jf out of range at {i}");
            }
        }
    }

    #[test]
    fn dangerous_syscalls_are_not_in_the_allowlist() {
        let plain = plain_allowed();
        for bad in [
            libc::SYS_sendto,
            libc::SYS_sendmsg,
            libc::SYS_sendmmsg,
            libc::SYS_socket,
            libc::SYS_connect,
            libc::SYS_bind,
            libc::SYS_openat,
            libc::SYS_execve,
            libc::SYS_ptrace,
            libc::SYS_setsockopt,
            libc::SYS_kill,
            libc::SYS_tgkill,
            libc::SYS_prctl,
            libc::SYS_capset,
            libc::SYS_read,
        ] {
            assert!(!plain.contains(&(bad as u32)), "syscall {bad} must not be unconditionally allowed");
        }
    }

    #[test]
    fn rejects_stdio_socket_fd() {
        assert!(install_seccomp(2).is_err());
    }
}
