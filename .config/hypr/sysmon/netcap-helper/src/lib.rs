//! netcap-helper: privileged half of sysmond's per-process network accounting.
//!
//! Trust model: this is the ONLY code that holds CAP_NET_RAW, and only for the
//! instant it takes to open one AF_PACKET socket. It then drops every
//! capability, sets no_new_privs/non-dumpable, and enters a seccomp allowlist
//! that permits just: recvfrom on that one socket, write to fd 1, memory
//! management, and exit. It has no input channel (stdin ignored, no argv),
//! reads no files after startup, and cannot send packets, open files, connect,
//! exec, or ptrace. It emits aggregate per-flow byte counts only (never
//! payload) down a one-way pipe; the unprivileged sysmond does all /proc
//! resolution and interpretation.

pub mod packet;
pub mod sandbox;
pub mod wire;
