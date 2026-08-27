//! Popup graph for the alt+mod+n/p/t keybinds (network/cpu/temperature),
//! replacing the KDE network-graph plasmoid. Reads history from `sysmond`
//! (autostarted in hyprland.lua) over a Unix socket rather than sampling
//! itself, so the graph already has minutes of history the instant it opens.
//!
//! Toggle/layer-shell/monitor-targeting conventions copied from
//! ~/.config/hypr/clipboard-picker/src/picker.rs -- second press of the
//! launching keybind closes the popup via a pidfile + SIGTERM, same as
//! clipboard-picker/notification-picker.

use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use gtk::prelude::*;
use gtk_layer_shell::{KeyboardMode, Layer, LayerShell};

use sysmon::{socket_path, Metric, Snapshot};

fn pidfile(program_name: &str) -> PathBuf {
    let base = std::env::var_os("XDG_RUNTIME_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/tmp"));
    base.join(format!("{program_name}.pid"))
}

/// Same toggle convention as clipboard-picker: a pidfile rather than pkill,
/// confirmed against /proc/<pid>/cmdline so a recycled PID can't be killed
/// by mistake. `program_name` is per-metric ("sysmon-graph-net" etc.) so
/// the three popups toggle independently of each other.
fn toggle_closed_existing(path: &Path) -> bool {
    let Ok(txt) = fs::read_to_string(path) else { return false };
    let Ok(pid) = txt.trim().parse::<i32>() else { return false };
    if pid == std::process::id() as i32 {
        return false;
    }
    let Ok(cmdline) = fs::read(format!("/proc/{pid}/cmdline")) else {
        return false; // process is gone; stale pidfile
    };
    if !String::from_utf8_lossy(&cmdline).contains("sysmon-graph") {
        return false; // PID recycled by something unrelated
    }
    unsafe { libc::kill(pid, libc::SIGTERM) == 0 }
}

/// The monitor Hyprland considers active (copied from picker.rs -- deliberately
/// not the monitor under the pointer, since focus-follows-mouse is off here).
fn target_monitor(display: &gdk::Display) -> Option<gdk::Monitor> {
    let focused = (|| {
        let out = std::process::Command::new("hyprctl").args(["-j", "monitors"]).output().ok()?;
        let v: serde_json::Value = serde_json::from_slice(&out.stdout).ok()?;
        for m in v.as_array()? {
            if m.get("focused")?.as_bool() == Some(true) {
                return Some((m.get("x")?.as_i64()? as i32, m.get("y")?.as_i64()? as i32));
            }
        }
        None
    })();

    if let Some((fx, fy)) = focused {
        for i in 0..display.n_monitors() {
            if let Some(mon) = display.monitor(i) {
                let g = mon.geometry();
                if g.x() == fx && g.y() == fy {
                    return Some(mon);
                }
            }
        }
    }
    display.monitor(0)
}

fn format_bytes_rate(bps: f64) -> String {
    if bps >= 1024.0 * 1024.0 {
        format!("{:.1} MB/s", bps / (1024.0 * 1024.0))
    } else if bps >= 1024.0 {
        format!("{:.0} KB/s", bps / 1024.0)
    } else {
        format!("{bps:.0} B/s")
    }
}

/// Connects to sysmond, spawning it if it isn't running yet (e.g. right
/// after this crate is built, before the next Hyprland restart re-runs the
/// hyprland.lua autostart block). Retries briefly since a freshly spawned
/// daemon needs a moment to bind its socket.
fn connect_daemon(metric: Metric) -> Option<UnixStream> {
    let path = socket_path();
    if let Ok(stream) = UnixStream::connect(&path) {
        return finish_handshake(stream, metric);
    }

    let daemon = std::env::current_exe()
        .ok()?
        .parent()?
        .join("sysmond");
    let _ = std::process::Command::new(daemon).spawn();

    for _ in 0..20 {
        std::thread::sleep(Duration::from_millis(100));
        if let Ok(stream) = UnixStream::connect(&path) {
            return finish_handshake(stream, metric);
        }
    }
    None
}

fn finish_handshake(mut stream: UnixStream, metric: Metric) -> Option<UnixStream> {
    let word = match metric {
        Metric::Net => "net\n",
        Metric::Cpu => "cpu\n",
        Metric::Temp => "temp\n",
        Metric::Mem => "mem\n",
        Metric::TopCpu => "topcpu\n",
        Metric::TopMem => "topmem\n",
        Metric::Disk => "disk\n",
    };
    stream.write_all(word.as_bytes()).ok()?;
    Some(stream)
}

fn draw_series(cr: &gtk::cairo::Context, w: f64, h: f64, series: &[f64], max_val: f64, rgb: (f64, f64, f64)) {
    draw_series_ex(cr, w, h, series, max_val, rgb, true, false);
}

/// `fill`: draw the area-under-the-line too (skipped for tx series when
/// overlaying several interfaces, so fills don't muddy each other).
/// `dashed`: stroke style, used to tell an interface's tx line from its rx
/// line while both share the same color.
fn draw_series_ex(
    cr: &gtk::cairo::Context,
    w: f64,
    h: f64,
    series: &[f64],
    max_val: f64,
    rgb: (f64, f64, f64),
    fill: bool,
    dashed: bool,
) {
    if series.len() < 2 || max_val <= 0.0 {
        return;
    }
    let n = series.len();
    let step = w / (n - 1) as f64;
    let y_of = |v: f64| h - (v / max_val).clamp(0.0, 1.0) * h;

    if fill {
        cr.move_to(0.0, h);
        for (i, v) in series.iter().enumerate() {
            cr.line_to(i as f64 * step, y_of(*v));
        }
        cr.line_to((n - 1) as f64 * step, h);
        cr.close_path();
        cr.set_source_rgba(rgb.0, rgb.1, rgb.2, 0.18);
        let _ = cr.fill_preserve();
    }

    cr.new_path();
    cr.move_to(0.0, y_of(series[0]));
    for (i, v) in series.iter().enumerate().skip(1) {
        cr.line_to(i as f64 * step, y_of(*v));
    }
    cr.set_source_rgba(rgb.0, rgb.1, rgb.2, 0.95);
    cr.set_line_width(2.0);
    if dashed {
        cr.set_dash(&[6.0, 4.0], 0.0);
    } else {
        cr.set_dash(&[], 0.0);
    }
    let _ = cr.stroke();
}

fn main() {
    let metric_arg = std::env::args().nth(1).unwrap_or_default();
    let Some(metric) = Metric::parse(&metric_arg) else {
        eprintln!("usage: sysmon-graph <net|cpu|temp|mem>");
        std::process::exit(1);
    };

    let pid_path = pidfile(&format!("sysmon-graph-{metric_arg}"));
    if toggle_closed_existing(&pid_path) {
        return;
    }

    if gtk::init().is_err() {
        eprintln!("sysmon-graph: failed to initialise GTK");
        std::process::exit(1);
    }
    let _ = fs::write(&pid_path, std::process::id().to_string());

    let Some(stream) = connect_daemon(metric) else {
        eprintln!("sysmon-graph: could not reach or start sysmond");
        let _ = fs::remove_file(&pid_path);
        std::process::exit(1);
    };

    let latest: Arc<Mutex<Option<Snapshot>>> = Arc::new(Mutex::new(None));
    {
        let latest = latest.clone();
        std::thread::spawn(move || {
            let mut reader = BufReader::new(stream);
            let mut line = String::new();
            loop {
                line.clear();
                match reader.read_line(&mut line) {
                    Ok(0) | Err(_) => return, // daemon gone
                    Ok(_) => {
                        if let Ok(snap) = serde_json::from_str::<Snapshot>(&line) {
                            *latest.lock().unwrap() = Some(snap);
                        }
                    }
                }
            }
        });
    }

    let (title, accent): (&str, (f64, f64, f64)) = match metric {
        Metric::Net => ("Network", (0.31, 0.84, 0.48)),  // rx color; tx uses a second fixed color below
        Metric::Cpu => ("CPU", (0.37, 0.63, 1.0)),
        Metric::Temp => ("Temperature", (1.0, 0.55, 0.25)),
        Metric::Mem => ("Memory", (0.78, 0.48, 1.0)),
        Metric::TopCpu => ("Top CPU", (0.37, 0.63, 1.0)),
        Metric::TopMem => ("Top Memory", (0.78, 0.48, 1.0)),
        Metric::Disk => ("Disk", (0.31, 0.84, 0.48)),
    };
    // One color per interface (not per rx/tx) for the multi-interface
    // network graph -- rx is drawn solid, tx dashed, same color, so
    // e.g. wlan0 and wg-wsl read as clearly distinct overlaid series.
    const IFACE_PALETTE: [(f64, f64, f64); 8] = [
        (0.20, 0.80, 1.00), // cyan
        (0.00, 1.00, 0.60), // green
        (1.00, 0.71, 0.33), // orange
        (0.78, 0.48, 1.00), // purple
        (1.00, 0.45, 0.65), // pink
        (0.95, 0.85, 0.30), // yellow
        (1.00, 0.42, 0.42), // red
        (0.55, 0.65, 1.00), // blue
    ];

    fn iface_color(name: &str) -> (f64, f64, f64) {
        let hash = name.bytes().fold(0u32, |acc, b| acc.wrapping_mul(31).wrapping_add(b as u32));
        IFACE_PALETTE[(hash as usize) % IFACE_PALETTE.len()]
    }

    let win = gtk::Window::new(gtk::WindowType::Toplevel);
    win.init_layer_shell();
    win.set_layer(Layer::Overlay);
    win.set_keyboard_mode(KeyboardMode::Exclusive);
    win.set_namespace("sysmon-graph");
    if let Some(display) = gdk::Display::default() {
        if let Some(mon) = target_monitor(&display) {
            win.set_monitor(&mon);
        }
    }
    win.set_size_request(460, 220);

    let provider = gtk::CssProvider::new();
    let _ = provider.load_from_data(
        b"window { background-color: rgba(24, 24, 32, 0.92); border-radius: 12px; }
          label.sysmon-title { color: #e8e8f0; font-weight: bold; font-size: 13px; padding: 10px 14px 0 14px; }
          label.sysmon-value { color: #b8b8c8; font-size: 12px; padding: 0 14px 8px 14px; }",
    );
    win.style_context()
        .add_provider(&provider, gtk::STYLE_PROVIDER_PRIORITY_APPLICATION);

    let vbox = gtk::Box::new(gtk::Orientation::Vertical, 0);
    let title_label = gtk::Label::new(Some(title));
    title_label.set_halign(gtk::Align::Start);
    title_label.style_context().add_class("sysmon-title");
    let value_label = gtk::Label::new(Some("--"));
    value_label.set_halign(gtk::Align::Start);
    value_label.style_context().add_class("sysmon-value");

    let area = gtk::DrawingArea::new();
    area.set_hexpand(true);
    area.set_vexpand(true);
    area.set_margin_start(8);
    area.set_margin_end(8);
    area.set_margin_bottom(8);

    vbox.add(&title_label);
    vbox.add(&value_label);
    vbox.add(&area);
    win.add(&vbox);

    {
        let latest = latest.clone();
        area.connect_draw(move |widget, cr| {
            let w = widget.allocated_width() as f64;
            let h = widget.allocated_height() as f64;
            let guard = latest.lock().unwrap();
            if let Some(snap) = guard.as_ref() {
                match snap {
                    Snapshot::Net { interfaces } => {
                        let max = interfaces
                            .iter()
                            .flat_map(|i| i.rx_bps.iter().chain(i.tx_bps.iter()))
                            .cloned()
                            .fold(1024.0_f64, f64::max);
                        for iface in interfaces {
                            let color = iface_color(&iface.name);
                            draw_series_ex(cr, w, h, &iface.tx_bps, max, color, false, true);
                            draw_series_ex(cr, w, h, &iface.rx_bps, max, color, true, false);
                        }
                    }
                    Snapshot::Cpu { total, .. } => draw_series(cr, w, h, total, 100.0, accent),
                    Snapshot::Temp { celsius } => {
                        let max = celsius.iter().cloned().fold(60.0_f64, f64::max) + 10.0;
                        draw_series(cr, w, h, celsius, max, accent);
                    }
                    Snapshot::Mem { used_pct, .. } => draw_series(cr, w, h, used_pct, 100.0, accent),
                    Snapshot::TopProcs { .. } => {} // not drawn as a graph; no popup UI for this yet
                    Snapshot::Disk { devices } => {
                        let max = devices
                            .iter()
                            .flat_map(|d| d.read_bps.iter().chain(d.write_bps.iter()))
                            .cloned()
                            .fold(1024.0_f64, f64::max);
                        for dev in devices {
                            let color = iface_color(&dev.name);
                            draw_series_ex(cr, w, h, &dev.write_bps, max, color, false, true);
                            draw_series_ex(cr, w, h, &dev.read_bps, max, color, true, false);
                        }
                    }
                }
            }
            glib::Propagation::Stop
        });
    }

    {
        let latest = latest.clone();
        let area = area.clone();
        let value_label = value_label.clone();
        glib::timeout_add_local(Duration::from_millis(300), move || {
            if let Some(snap) = latest.lock().unwrap().as_ref() {
                let text = match snap {
                    Snapshot::Net { interfaces } => {
                        let mut names: Vec<&sysmon::IfaceHistory> = interfaces.iter().collect();
                        names.sort_by(|a, b| a.name.cmp(&b.name));
                        names
                            .iter()
                            .map(|i| {
                                format!(
                                    "{}: \u{2193}{} \u{2191}{}",
                                    i.name,
                                    format_bytes_rate(i.rx_bps.last().copied().unwrap_or(0.0)),
                                    format_bytes_rate(i.tx_bps.last().copied().unwrap_or(0.0)),
                                )
                            })
                            .collect::<Vec<_>>()
                            .join("   ")
                    }
                    Snapshot::Cpu { total, .. } => format!("{:.0}%", total.last().copied().unwrap_or(0.0)),
                    Snapshot::Temp { celsius } => format!("{:.0}\u{b0}C", celsius.last().copied().unwrap_or(0.0)),
                    Snapshot::Mem { used_pct, .. } => format!("{:.0}%", used_pct.last().copied().unwrap_or(0.0)),
                    Snapshot::TopProcs { procs } => procs.first().map(|p| format!("{} ({:.0})", p.name, p.value)).unwrap_or_default(),
                    Snapshot::Disk { devices } => {
                        let mut names: Vec<&sysmon::DiskHistory> = devices.iter().collect();
                        names.sort_by(|a, b| a.name.cmp(&b.name));
                        names
                            .iter()
                            .map(|d| {
                                format!(
                                    "{}: R{} W{}",
                                    d.name,
                                    format_bytes_rate(d.read_bps.last().copied().unwrap_or(0.0)),
                                    format_bytes_rate(d.write_bps.last().copied().unwrap_or(0.0)),
                                )
                            })
                            .collect::<Vec<_>>()
                            .join("   ")
                    }
                };
                value_label.set_text(&text);
            }
            area.queue_draw();
            glib::ControlFlow::Continue
        });
    }

    win.connect_key_press_event(|_, ev| {
        use gdk::keys::constants as key;
        if ev.keyval() == key::Escape {
            gtk::main_quit();
            return glib::Propagation::Stop;
        }
        glib::Propagation::Proceed
    });
    win.connect_destroy(|_| gtk::main_quit());

    {
        let pid_path = pid_path.clone();
        glib::unix_signal_add_local(libc::SIGTERM, move || {
            let _ = fs::remove_file(&pid_path);
            gtk::main_quit();
            glib::ControlFlow::Break
        });
    }

    win.show_all();
    gtk::main();
    let _ = fs::remove_file(&pid_path);
}
