//! Prints per-interface, per-process network rates from netcap-helper, one
//! block per second. For verifying an install (`netcap-probe`) and for the
//! namespace end-to-end test (SYSMON_NETCAP_HELPER=... SYSMON_NETCAP_LO=1).

fn main() {
    let secs: u64 = std::env::args().nth(1).and_then(|s| s.parse().ok()).unwrap_or(5);
    if let Err(e) = sysmon::netcap::start(|report| {
        let mut ifaces: Vec<_> = report.into_iter().collect();
        ifaces.sort_by(|a, b| a.0.cmp(&b.0));
        for (iface, mut samples) in ifaces {
            samples.sort_by(|a, b| (b.2 + b.3).partial_cmp(&(a.2 + a.3)).unwrap_or(std::cmp::Ordering::Equal));
            for (pid, name, sent, recv) in samples {
                println!("{iface}\t{pid}\t{name}\tsent={sent:.1}KB/s\trecv={recv:.1}KB/s");
            }
        }
        println!("--");
    }) {
        eprintln!("netcap-probe: helper unavailable: {e}");
        std::process::exit(1);
    }
    std::thread::sleep(std::time::Duration::from_secs(secs));
}
