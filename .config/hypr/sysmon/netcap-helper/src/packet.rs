//! Network-layer header parsing. Pure and panic-free on arbitrary input: every
//! index is guarded by an explicit length check (see the exhaustive/fuzz tests).

pub const PROTO_TCP: u8 = 6;
pub const PROTO_UDP: u8 = 17;

pub type Ip = [u8; 16]; // IPv4 stored v4-mapped (::ffff:a.b.c.d)

#[derive(Clone, Copy, PartialEq, Eq, Hash, Debug)]
pub struct Flow {
    pub proto: u8,
    pub lip: Ip,
    pub lport: u16,
    pub rip: Ip,
    pub rport: u16,
}

fn v4(b: &[u8; 4]) -> Ip {
    let mut ip = [0u8; 16];
    ip[10] = 0xff;
    ip[11] = 0xff;
    ip[12..16].copy_from_slice(b);
    ip
}

/// Parses an IPv4/IPv6 header + the first 4 bytes of a TCP/UDP header from a
/// (possibly truncated) packet snapshot. `outgoing` orients local/remote.
/// Anything else (other protocols, extension headers, non-first fragments,
/// short or malformed data) yields `None`.
pub fn parse(buf: &[u8], ethertype: u16, outgoing: bool) -> Option<Flow> {
    let (proto, src, dst, l4): (u8, Ip, Ip, usize) = match ethertype {
        0x0800 => {
            let h = buf.get(..20)?;
            if h[0] >> 4 != 4 {
                return None;
            }
            let ihl = usize::from(h[0] & 0x0f) * 4;
            if ihl < 20 {
                return None;
            }
            if u16::from_be_bytes([h[6], h[7]]) & 0x1fff != 0 {
                return None; // non-first fragment: no L4 header
            }
            let s: [u8; 4] = h[12..16].try_into().ok()?;
            let d: [u8; 4] = h[16..20].try_into().ok()?;
            (h[9], v4(&s), v4(&d), ihl)
        }
        0x86dd => {
            let h = buf.get(..40)?;
            if h[0] >> 4 != 6 {
                return None;
            }
            let s: Ip = h[8..24].try_into().ok()?;
            let d: Ip = h[24..40].try_into().ok()?;
            (h[6], s, d, 40)
        }
        _ => return None,
    };
    if proto != PROTO_TCP && proto != PROTO_UDP {
        return None;
    }
    let end = l4.checked_add(4)?;
    let ports = buf.get(l4..end)?;
    let sport = u16::from_be_bytes([ports[0], ports[1]]);
    let dport = u16::from_be_bytes([ports[2], ports[3]]);
    Some(if outgoing {
        Flow { proto, lip: src, lport: sport, rip: dst, rport: dport }
    } else {
        Flow { proto, lip: dst, lport: dport, rip: src, rport: sport }
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ipv4(proto: u8, ihl_words: u8, src: [u8; 4], dst: [u8; 4], sp: u16, dp: u16) -> Vec<u8> {
        let mut p = vec![0x40 | ihl_words, 0, 0, 28, 0, 0, 0, 0, 64, proto, 0, 0];
        p.extend_from_slice(&src);
        p.extend_from_slice(&dst);
        p.resize(usize::from(ihl_words) * 4, 0);
        p.extend_from_slice(&sp.to_be_bytes());
        p.extend_from_slice(&dp.to_be_bytes());
        p
    }

    fn ipv6(proto: u8, src: Ip, dst: Ip, sp: u16, dp: u16) -> Vec<u8> {
        let mut p = vec![0x60, 0, 0, 0, 0, 20, proto, 64];
        p.extend_from_slice(&src);
        p.extend_from_slice(&dst);
        p.extend_from_slice(&sp.to_be_bytes());
        p.extend_from_slice(&dp.to_be_bytes());
        p
    }

    #[test]
    fn orients_by_direction() {
        let p = ipv4(17, 5, [10, 0, 0, 1], [1, 1, 1, 1], 5000, 53);
        let out = parse(&p, 0x0800, true).unwrap();
        assert_eq!((out.lport, out.rport, out.lip, out.rip), (5000, 53, v4(&[10, 0, 0, 1]), v4(&[1, 1, 1, 1])));
        let inc = parse(&p, 0x0800, false).unwrap();
        assert_eq!((inc.lport, inc.rport, inc.lip, inc.rip), (53, 5000, v4(&[1, 1, 1, 1]), v4(&[10, 0, 0, 1])));
    }

    #[test]
    fn ipv4_options_shift_l4_offset() {
        let p = ipv4(6, 7, [1, 2, 3, 4], [5, 6, 7, 8], 443, 50000); // IHL=28
        let f = parse(&p, 0x0800, true).unwrap();
        assert_eq!((f.proto, f.lport, f.rport), (PROTO_TCP, 443, 50000));
    }

    #[test]
    fn ipv6_tcp() {
        let mut s = [0u8; 16];
        s[15] = 1;
        let mut d = [0u8; 16];
        d[0] = 0x20;
        d[1] = 1;
        let f = parse(&ipv6(6, s, d, 443, 50000), 0x86dd, false).unwrap();
        assert_eq!((f.proto, f.lport, f.rport, f.lip, f.rip), (PROTO_TCP, 50000, 443, d, s));
    }

    #[test]
    fn rejects_non_tcp_udp_fragments_bad_version_and_ihl() {
        assert!(parse(&ipv4(1, 5, [1; 4], [2; 4], 1, 2), 0x0800, true).is_none()); // ICMP
        let mut frag = ipv4(17, 5, [1; 4], [2; 4], 1, 2);
        frag[7] = 8;
        assert!(parse(&frag, 0x0800, true).is_none());
        let mut ver = ipv4(17, 5, [1; 4], [2; 4], 1, 2);
        ver[0] = 0x65;
        assert!(parse(&ver, 0x0800, true).is_none());
        let mut ihl = ipv4(17, 5, [1; 4], [2; 4], 1, 2);
        ihl[0] = 0x43; // IHL 12 < 20
        assert!(parse(&ihl, 0x0800, true).is_none());
        assert!(parse(&ipv4(17, 5, [1; 4], [2; 4], 1, 2), 0x0806, true).is_none()); // ARP
        assert!(parse(&ipv6(58, [0; 16], [0; 16], 1, 2), 0x86dd, true).is_none()); // ICMPv6
    }

    /// Every truncation of every valid shape, in both directions, never panics
    /// and never yields a flow unless the full L4 ports were present.
    #[test]
    fn all_truncations_are_safe() {
        let shapes = [
            (ipv4(6, 5, [9; 4], [8; 4], 1, 2), 0x0800u16, 24usize),
            (ipv4(17, 15, [9; 4], [8; 4], 1, 2), 0x0800, 64),
            (ipv6(17, [3; 16], [4; 16], 1, 2), 0x86dd, 44),
        ];
        for (pkt, et, need) in shapes {
            for cut in 0..=pkt.len() + 2 {
                let slice = &pkt[..cut.min(pkt.len())];
                for out in [true, false] {
                    let r = parse(slice, et, out);
                    if slice.len() < need {
                        assert!(r.is_none(), "cut={cut} produced a flow from a short packet");
                    } else {
                        assert!(r.is_some());
                    }
                }
            }
        }
    }

    /// Deterministic xorshift fuzz: random bytes with a plausible first byte and
    /// every ethertype class must never panic (overflow-checks are on in tests).
    #[test]
    fn random_bytes_never_panic() {
        let mut x: u64 = 0x9e3779b97f4a7c15;
        let mut next = || {
            x ^= x << 13;
            x ^= x >> 7;
            x ^= x << 17;
            x
        };
        let mut buf = [0u8; 64];
        for i in 0..2_000_000u32 {
            let len = (next() % 65) as usize;
            for b in buf.iter_mut().take(len) {
                *b = next() as u8;
            }
            if len > 0 && i % 2 == 0 {
                buf[0] = if i % 4 == 0 { 0x40 | (next() as u8 & 0x0f) } else { 0x60 };
            }
            if len > 9 && i % 3 == 0 {
                buf[9] = if i % 6 == 0 { 6 } else { 17 };
                buf[6] = 0; // dodge the fragment filter more often
                buf[7] = 0;
            }
            let et = [0x0800u16, 0x86dd, 0x0806, 0][(next() % 4) as usize];
            let _ = parse(&buf[..len], et, i % 2 == 0);
        }
    }
}
