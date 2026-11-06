//! Fixed-size little-endian wire format helper -> sysmond (one-way pipe).
//!
//! Stream = one HELLO header (n_records = 0, sent once the sandbox is fully
//! installed, so the reader knows the helper is healthy) followed by TICK
//! frames: a 16-byte header then `n_records` 64-byte records.
//!
//! header:  u32 magic | u32 n_records | u32 elapsed_ms | u32 reserved(0)
//! record:  u32 ifindex | u8 proto | 3 zero | [u8;16] local_ip | [u8;16] remote_ip
//!          | u16 local_port | u16 remote_port | 4 zero | u64 sent_bytes | u64 recv_bytes
//! IPv4 addresses are v4-mapped (::ffff:a.b.c.d).

pub const MAGIC_HELLO: u32 = u32::from_le_bytes(*b"NCH1");
pub const MAGIC_TICK: u32 = u32::from_le_bytes(*b"NCP1");
pub const HEADER_LEN: usize = 16;
pub const RECORD_LEN: usize = 64;
/// Hard cap on records per tick frame; readers must reject anything larger.
pub const MAX_RECORDS: u32 = 20_000;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Record {
    pub ifindex: u32,
    pub proto: u8,
    pub lip: [u8; 16],
    pub lport: u16,
    pub rip: [u8; 16],
    pub rport: u16,
    pub sent: u64,
    pub recv: u64,
}

pub fn encode_header(magic: u32, n_records: u32, elapsed_ms: u32) -> [u8; HEADER_LEN] {
    let mut b = [0u8; HEADER_LEN];
    b[0..4].copy_from_slice(&magic.to_le_bytes());
    b[4..8].copy_from_slice(&n_records.to_le_bytes());
    b[8..12].copy_from_slice(&elapsed_ms.to_le_bytes());
    b
}

pub fn encode_record(r: &Record) -> [u8; RECORD_LEN] {
    let mut b = [0u8; RECORD_LEN];
    b[0..4].copy_from_slice(&r.ifindex.to_le_bytes());
    b[4] = r.proto;
    b[8..24].copy_from_slice(&r.lip);
    b[24..40].copy_from_slice(&r.rip);
    b[40..42].copy_from_slice(&r.lport.to_le_bytes());
    b[42..44].copy_from_slice(&r.rport.to_le_bytes());
    b[48..56].copy_from_slice(&r.sent.to_le_bytes());
    b[56..64].copy_from_slice(&r.recv.to_le_bytes());
    b
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn golden_bytes() {
        let r = Record { ifindex: 2, proto: 17, lip: [1; 16], lport: 0x1234, rip: [2; 16], rport: 0x5678, sent: 0x0102030405060708, recv: 9 };
        let b = encode_record(&r);
        assert_eq!(&b[0..4], &[2, 0, 0, 0]);
        assert_eq!(b[4], 17);
        assert_eq!(&b[5..8], &[0, 0, 0]);
        assert_eq!(&b[8..24], &[1u8; 16]);
        assert_eq!(&b[24..40], &[2u8; 16]);
        assert_eq!(&b[40..44], &[0x34, 0x12, 0x78, 0x56]);
        assert_eq!(&b[44..48], &[0, 0, 0, 0]);
        assert_eq!(&b[48..56], &[8, 7, 6, 5, 4, 3, 2, 1]);
        assert_eq!(&b[56..64], &[9, 0, 0, 0, 0, 0, 0, 0]);
    }

    #[test]
    fn header_golden() {
        let h = encode_header(MAGIC_TICK, 3, 1000);
        assert_eq!(&h[0..4], b"NCP1");
        assert_eq!(&h[4..8], &[3, 0, 0, 0]);
        assert_eq!(&h[8..12], &1000u32.to_le_bytes());
        assert_eq!(&h[12..16], &[0; 4]);
        assert_eq!(&encode_header(MAGIC_HELLO, 0, 0)[0..4], b"NCH1");
    }
}
