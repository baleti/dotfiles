//! Verbatim copy of ~/.config/hypr/winswitch/src/wayland_capture.rs (same
//! for protocol.rs and protocols/*.xml alongside this file) -- this crate
//! is intentionally its own standalone binary, not a dependency on or
//! subcommand of winswitch, so the claude-usage bar panel's hover-
//! thumbnail feature has no runtime coupling to winswitch's build. Only
//! `hyprctl::Window`'s `address` field is used here (the rest of that
//! struct, and everything below needing class/title/workspace/pid/size,
//! is winswitch's own UI-layer concern, not this capture path's).
//!
//! Live window thumbnails via `hyprland-toplevel-export-v1`. A completely
//! separate low-level `wayland-client` connection from GTK's own (GDK
//! doesn't expose these extension protocols): enumerate every open toplevel
//! via `wlr-foreign-toplevel-management-unstable-v1`, resolve each one's
//! Hyprland window `address` via `hyprland-toplevel-mapping-v1` (matched
//! against the addresses already known from `hyprctl clients -j`), then
//! capture a frame of each matched toplevel and stream the decoded pixels
//! back into the grid as they arrive.
//!
//! Bootstrapping (registry -> bind -> enumerate toplevels -> resolve
//! addresses -> kick off captures) is driven with a few blocking
//! `roundtrip()`s at startup -- cheap, local-socket round trips, and it
//! keeps the setup code a straight line instead of a hand-rolled async state
//! machine. Everything after that (the actual frame buffer negotiation and
//! pixel copy, which can take a moment per window) is unblocking: the
//! connection's fd is registered with glib's main loop, same trick as the
//! forwarding socket in `ui.rs`.

use std::collections::HashMap;
use std::os::fd::{AsFd, AsRawFd};

use gdk_pixbuf::Pixbuf;
use wayland_client::backend::ObjectId;
use wayland_client::protocol::{wl_buffer, wl_registry, wl_shm, wl_shm_pool};
use wayland_client::{Connection, Dispatch, Proxy, QueueHandle, WEnum};

use crate::hyprctl::Window;
use crate::protocol::hyprland_toplevel_export_v1::hyprland_toplevel_export_frame_v1::{
    self, HyprlandToplevelExportFrameV1,
};
use crate::protocol::hyprland_toplevel_export_v1::hyprland_toplevel_export_manager_v1::HyprlandToplevelExportManagerV1;
use crate::protocol::hyprland_toplevel_mapping_v1::hyprland_toplevel_mapping_manager_v1::HyprlandToplevelMappingManagerV1;
use crate::protocol::hyprland_toplevel_mapping_v1::hyprland_toplevel_window_mapping_handle_v1::{
    self, HyprlandToplevelWindowMappingHandleV1,
};
use crate::protocol::wlr_foreign_toplevel_management_unstable_v1::zwlr_foreign_toplevel_handle_v1::ZwlrForeignToplevelHandleV1;
use crate::protocol::wlr_foreign_toplevel_management_unstable_v1::zwlr_foreign_toplevel_manager_v1::{
    self, ZwlrForeignToplevelManagerV1,
};

fn parse_address(addr: &str) -> Option<u64> {
    u64::from_str_radix(addr.trim_start_matches("0x"), 16).ok()
}

/// Accumulates a frame's `buffer` params until `buffer_done`, then the shm
/// pool/buffer/mmap needed to actually receive the copy.
struct PendingFrame {
    index: usize,
    width: u32,
    height: u32,
    stride: u32,
    format: Option<wl_shm::Format>,
    mmap: Option<memmap2::MmapMut>,
    buffer: Option<wl_buffer::WlBuffer>,
    pool: Option<wl_shm_pool::WlShmPool>,
}

struct Capture {
    shm: Option<wl_shm::WlShm>,
    toplevel_manager: Option<ZwlrForeignToplevelManagerV1>,
    mapping_manager: Option<HyprlandToplevelMappingManagerV1>,
    export_manager: Option<HyprlandToplevelExportManagerV1>,
    address_to_index: HashMap<u64, usize>,
    pending_frames: HashMap<ObjectId, PendingFrame>,
    on_thumbnail: Box<dyn Fn(usize, Pixbuf)>,
}

/// BGRA/BGRX (wl_shm native-endian argb8888/xrgb8888 on a little-endian
/// machine) -> tightly packed RGBA, forcing full opacity for the xrgb8888
/// case (its 4th byte is unspecified padding, not real alpha).
fn convert_to_rgba(src: &[u8], width: u32, height: u32, stride: u32, has_alpha: bool) -> Vec<u8> {
    let (w, h, stride) = (width as usize, height as usize, stride as usize);
    let mut out = vec![0u8; w * h * 4];
    for y in 0..h {
        let row = &src[y * stride..y * stride + w * 4];
        let out_row = &mut out[y * w * 4..(y + 1) * w * 4];
        for x in 0..w {
            let px = &row[x * 4..x * 4 + 4];
            let o = &mut out_row[x * 4..x * 4 + 4];
            o[0] = px[2]; // R
            o[1] = px[1]; // G
            o[2] = px[0]; // B
            o[3] = if has_alpha { px[3] } else { 255 };
        }
    }
    out
}

fn create_memfd(size: u64) -> std::io::Result<std::fs::File> {
    use std::ffi::CString;
    use std::os::fd::FromRawFd;
    let name = CString::new("winswitch-thumb").unwrap();
    let fd = unsafe { libc::memfd_create(name.as_ptr(), 0) };
    if fd < 0 {
        return Err(std::io::Error::last_os_error());
    }
    let file = unsafe { std::fs::File::from_raw_fd(fd) };
    file.set_len(size)?;
    Ok(file)
}

impl Dispatch<wl_registry::WlRegistry, ()> for Capture {
    fn event(
        state: &mut Self,
        registry: &wl_registry::WlRegistry,
        event: wl_registry::Event,
        _data: &(),
        _conn: &Connection,
        qh: &QueueHandle<Self>,
    ) {
        if let wl_registry::Event::Global { name, interface, version } = event {
            match interface.as_str() {
                "wl_shm" => {
                    state.shm = Some(registry.bind::<wl_shm::WlShm, _, _>(name, version.min(1), qh, ()));
                }
                "zwlr_foreign_toplevel_manager_v1" => {
                    state.toplevel_manager = Some(registry.bind::<ZwlrForeignToplevelManagerV1, _, _>(
                        name,
                        version.min(3),
                        qh,
                        (),
                    ));
                }
                "hyprland_toplevel_mapping_manager_v1" => {
                    state.mapping_manager = Some(registry.bind::<HyprlandToplevelMappingManagerV1, _, _>(
                        name,
                        version.min(1),
                        qh,
                        (),
                    ));
                }
                "hyprland_toplevel_export_manager_v1" => {
                    state.export_manager = Some(registry.bind::<HyprlandToplevelExportManagerV1, _, _>(
                        name,
                        version.min(2),
                        qh,
                        (),
                    ));
                }
                _ => {}
            }
        }
    }
}

impl Dispatch<wl_shm::WlShm, ()> for Capture {
    fn event(_: &mut Self, _: &wl_shm::WlShm, _: wl_shm::Event, _: &(), _: &Connection, _: &QueueHandle<Self>) {}
}

impl Dispatch<ZwlrForeignToplevelManagerV1, ()> for Capture {
    fn event(
        state: &mut Self,
        _proxy: &ZwlrForeignToplevelManagerV1,
        event: zwlr_foreign_toplevel_manager_v1::Event,
        _data: &(),
        _conn: &Connection,
        qh: &QueueHandle<Self>,
    ) {
        if let zwlr_foreign_toplevel_manager_v1::Event::Toplevel { toplevel } = event {
            if let Some(mapping_manager) = &state.mapping_manager {
                mapping_manager.get_window_for_toplevel_wlr(&toplevel, qh, toplevel.clone());
            }
        }
    }

    wayland_client::event_created_child!(Capture, ZwlrForeignToplevelManagerV1, [
        0 => (ZwlrForeignToplevelHandleV1, ()),
    ]);
}

impl Dispatch<ZwlrForeignToplevelHandleV1, ()> for Capture {
    fn event(
        _: &mut Self,
        _: &ZwlrForeignToplevelHandleV1,
        _: <ZwlrForeignToplevelHandleV1 as Proxy>::Event,
        _: &(),
        _: &Connection,
        _: &QueueHandle<Self>,
    ) {
        // We only care about correlating by address (handled via the
        // mapping handle) and don't need title/app_id/output/state churn.
    }
}

impl Dispatch<HyprlandToplevelWindowMappingHandleV1, ZwlrForeignToplevelHandleV1> for Capture {
    fn event(
        state: &mut Self,
        _proxy: &HyprlandToplevelWindowMappingHandleV1,
        event: hyprland_toplevel_window_mapping_handle_v1::Event,
        toplevel: &ZwlrForeignToplevelHandleV1,
        _conn: &Connection,
        qh: &QueueHandle<Self>,
    ) {
        if let hyprland_toplevel_window_mapping_handle_v1::Event::WindowAddress { address_hi, address } = event {
            let addr = ((address_hi as u64) << 32) | address as u64;
            if let Some(&index) = state.address_to_index.get(&addr) {
                if let Some(export_manager) = &state.export_manager {
                    export_manager.capture_toplevel_with_wlr_toplevel_handle(0, toplevel, qh, index);
                }
            }
        }
        // `Failed` (mapping couldn't resolve): leave the icon placeholder.
    }
}

impl Dispatch<HyprlandToplevelExportFrameV1, usize> for Capture {
    fn event(
        state: &mut Self,
        frame: &HyprlandToplevelExportFrameV1,
        event: hyprland_toplevel_export_frame_v1::Event,
        index: &usize,
        _conn: &Connection,
        qh: &QueueHandle<Self>,
    ) {
        use hyprland_toplevel_export_frame_v1::Event;
        let id = frame.id();
        match event {
            Event::Buffer { format, width, height, stride } => {
                let format = match format {
                    WEnum::Value(f) => Some(f),
                    WEnum::Unknown(_) => None,
                };
                state.pending_frames.insert(
                    id,
                    PendingFrame {
                        index: *index,
                        width,
                        height,
                        stride,
                        format,
                        mmap: None,
                        buffer: None,
                        pool: None,
                    },
                );
            }
            Event::BufferDone => {
                let Some(shm) = &state.shm else { return };
                let Some(pf) = state.pending_frames.get_mut(&id) else { return };
                let Some(format) = pf.format else { return };
                let size = (pf.stride as u64) * (pf.height as u64);
                let Ok(file) = create_memfd(size) else { return };
                let Ok(mmap) = (unsafe { memmap2::MmapMut::map_mut(&file) }) else { return };
                let pool = shm.create_pool(file.as_fd(), size as i32, qh, ());
                let buffer = pool.create_buffer(
                    0,
                    pf.width as i32,
                    pf.height as i32,
                    pf.stride as i32,
                    format,
                    qh,
                    (),
                );
                frame.copy(&buffer, 1);
                pf.mmap = Some(mmap);
                pf.buffer = Some(buffer);
                pf.pool = Some(pool);
            }
            Event::Ready { .. } => {
                if let Some(pf) = state.pending_frames.remove(&id) {
                    if let (Some(mmap), Some(format)) = (&pf.mmap, pf.format) {
                        let has_alpha = matches!(format, wl_shm::Format::Argb8888);
                        let rgba = convert_to_rgba(mmap, pf.width, pf.height, pf.stride, has_alpha);
                        let pb = Pixbuf::from_mut_slice(
                            rgba,
                            gdk_pixbuf::Colorspace::Rgb,
                            true,
                            8,
                            pf.width as i32,
                            pf.height as i32,
                            (pf.width * 4) as i32,
                        );
                        (state.on_thumbnail)(pf.index, pb);
                    }
                    if let Some(buffer) = pf.buffer {
                        buffer.destroy();
                    }
                    if let Some(pool) = pf.pool {
                        pool.destroy();
                    }
                }
                frame.destroy();
            }
            Event::Failed => {
                state.pending_frames.remove(&id);
                frame.destroy();
            }
            _ => {}
        }
    }
}

impl Dispatch<wl_shm_pool::WlShmPool, ()> for Capture {
    fn event(_: &mut Self, _: &wl_shm_pool::WlShmPool, _: wl_shm_pool::Event, _: &(), _: &Connection, _: &QueueHandle<Self>) {}
}

impl Dispatch<wl_buffer::WlBuffer, ()> for Capture {
    fn event(_: &mut Self, _: &wl_buffer::WlBuffer, _: wl_buffer::Event, _: &(), _: &Connection, _: &QueueHandle<Self>) {}
}

impl Dispatch<HyprlandToplevelMappingManagerV1, ()> for Capture {
    fn event(
        _: &mut Self,
        _: &HyprlandToplevelMappingManagerV1,
        _: <HyprlandToplevelMappingManagerV1 as Proxy>::Event,
        _: &(),
        _: &Connection,
        _: &QueueHandle<Self>,
    ) {
    }
}

impl Dispatch<HyprlandToplevelExportManagerV1, ()> for Capture {
    fn event(
        _: &mut Self,
        _: &HyprlandToplevelExportManagerV1,
        _: <HyprlandToplevelExportManagerV1 as Proxy>::Event,
        _: &(),
        _: &Connection,
        _: &QueueHandle<Self>,
    ) {
    }
}

/// Kicks off live thumbnail capture for `windows` and wires the connection's
/// fd into glib's main loop so the rest of the work (frame negotiation +
/// copy, which streams in over the following frames) doesn't block the UI.
/// `on_thumbnail(index, pixbuf)` is called once per window that
/// successfully captures, in `windows` order -- may be called zero times
/// for a given window if e.g. its mapping or capture fails.
pub fn start(windows: &[Window], on_thumbnail: impl Fn(usize, Pixbuf) + 'static) {
    let Ok(conn) = Connection::connect_to_env() else {
        return;
    };
    let mut event_queue = conn.new_event_queue();
    let qh = event_queue.handle();
    let display = conn.display();
    let _registry = display.get_registry(&qh, ());

    let address_to_index = windows
        .iter()
        .enumerate()
        .filter_map(|(i, w)| parse_address(&w.address).map(|a| (a, i)))
        .collect();

    let mut state = Capture {
        shm: None,
        toplevel_manager: None,
        mapping_manager: None,
        export_manager: None,
        address_to_index,
        pending_frames: HashMap::new(),
        on_thumbnail: Box::new(on_thumbnail),
    };

    // registry globals + bind requests, then the bound managers' initial
    // toplevel-enumeration events, then the address-mapping events that
    // enumeration triggers -- each step's requests only go out once the
    // previous roundtrip flushes, so this has to be three, not one.
    for _ in 0..3 {
        if event_queue.roundtrip(&mut state).is_err() {
            return;
        }
    }

    event_queue.flush().ok();
    let raw_fd = conn.as_fd().as_raw_fd();
    // `conn` is captured (not just its raw fd) so the connection stays open
    // for as long as this fd-watch source lives -- which for this
    // fire-and-forget, on-demand process is its whole remaining lifetime.
    glib::source::unix_fd_add_local(raw_fd, glib::IOCondition::IN, move |_, _| {
        let _conn = &conn;
        if let Some(guard) = event_queue.prepare_read() {
            let _ = guard.read();
        }
        let _ = event_queue.dispatch_pending(&mut state);
        let _ = event_queue.flush();
        glib::ControlFlow::Continue
    });
}
