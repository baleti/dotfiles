//! Live window thumbnails via `hyprland-toplevel-export-v1`. A completely
//! separate low-level `wayland-client` connection from GTK's own (GDK
//! doesn't expose these extension protocols): enumerate every open toplevel
//! via `wlr-foreign-toplevel-management-unstable-v1`, resolve each one's
//! Hyprland window `address` via `hyprland-toplevel-mapping-v1` (matched
//! against the addresses already known from `hyprctl clients -j`), then
//! capture a frame of each matched toplevel and stream the decoded pixels
//! back into the grid as they arrive.
//!
//! Everything -- the registry/bind/enumerate/resolve bootstrapping *and* the
//! frame negotiation and pixel copy that follows -- runs on a dedicated
//! background thread with its own connection, so the caller (`main.rs`) is
//! free to get on with enumerating/printing other things while captures
//! stream in. `start()` spawns that thread and returns the raw
//! `mpsc::Receiver<ThumbMsg>` immediately; the caller drains it however
//! suits it (`main.rs` prints an NDJSON line per message) -- this module has
//! no opinion on threading model or output format, unlike its previous
//! GTK/glib-integrated incarnation.
//!
//! Each captured frame is also downscaled *during* its one conversion pass
//! (nearest-neighbor sampling straight from the source BGRA buffer into a
//! pre-sized RGBA one) rather than converted at full resolution and resized
//! after -- a window several times larger than `MAX_THUMB_EDGE` means the
//! second pass would otherwise touch many more pixels than any thumbnail
//! ever needs. The target size here is only a cap on the long edge, not an
//! exact final size the way it once was fit to a specific GTK grid cell:
//! the QML frontend does its own final aspect-fit sizing per cell
//! (`Image.fillMode: PreserveAspectFit`), so this module doesn't need to
//! know anything about grid layout at all.
//!
//! ## The `linux_dmabuf` path (and why it's safe on this GPU setup)
//!
//! `hyprland-toplevel-export-v1` offers each frame as either a `wl_shm`
//! buffer (the only kind used above until now -- the compositor renders the
//! window, downloads it GPU->CPU itself, and hands us the CPU copy) or a
//! `linux_dmabuf` one (a GPU buffer handle -- the compositor renders
//! straight into a buffer *we* allocate, no compositor-side readback at
//! all; whatever CPU read we still need happens in this process instead,
//! off the compositor's own render thread). `try_dmabuf` below takes that
//! path when it can and `copy_via_shm` is the fallback, used directly when
//! it can't and also if the dmabuf attempt itself gets rejected.
//!
//! This machine has a known, currently-pinned mesa bug
//! (`mesa_26_2_2_hyprland_crash_pin` in the assistant's memory) where
//! Hyprland's own renderer aborts the whole compositor importing a
//! cross-GPU dmabuf (an NVIDIA-tiled buffer, composited on the Intel iGPU)
//! -- `eglCreateImageKHR` failing with `EGL_BAD_MATCH`, then a *separate*,
//! genuinely buggy fallback path inside Hyprland's frame-end EGL sync
//! (`dri_create_fence_fd`) aborting. This module never risks that class of
//! failure for two independent reasons: it never touches EGL/GL at all --
//! the destination buffer is allocated `LINEAR` (untiled) via plain GBM and
//! read back with a plain `gbm_bo_map` CPU mapping, so there's no
//! EGLImage/fence path here to hit the same bug in; and it only ever
//! requests a (format, modifier) pair the compositor's `zwp_linux_dmabuf_v1`
//! global has itself already advertised as supported (`dmabuf_modifiers`,
//! collected once at startup), so it can't even attempt an import the
//! compositor didn't say it could do. If a dmabuf attempt is still rejected
//! at runtime anyway (`zwp_linux_buffer_params_v1`'s `Failed` event -- an
//! explicitly non-fatal outcome the protocol defines for exactly this,
//! which is why `create` is used here instead of `create_immed`), this
//! module just falls back to the wl_shm path for that one window. Worst
//! case of any of this going wrong is this background thread's own
//! connection erroring out -- this is a separate process from Hyprland with
//! its own GBM/EGL state; nothing here runs inside the compositor.

use std::collections::{HashMap, HashSet};
use std::fs::File;
use std::os::fd::AsFd;
use std::path::PathBuf;
use std::sync::mpsc;
use std::time::Duration;

use gbm::{BufferObject, BufferObjectFlags, Device as GbmDevice, Format as DrmFormat, Modifier as DrmModifier};
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
use crate::protocol::linux_dmabuf_v1::zwp_linux_buffer_params_v1::{self, ZwpLinuxBufferParamsV1};
use crate::protocol::linux_dmabuf_v1::zwp_linux_dmabuf_v1::{self, ZwpLinuxDmabufV1};
use crate::protocol::wlr_foreign_toplevel_management_unstable_v1::zwlr_foreign_toplevel_handle_v1::ZwlrForeignToplevelHandleV1;
use crate::protocol::wlr_foreign_toplevel_management_unstable_v1::zwlr_foreign_toplevel_manager_v1::{
    self, ZwlrForeignToplevelManagerV1,
};

fn parse_address(addr: &str) -> Option<u64> {
    u64::from_str_radix(addr.trim_start_matches("0x"), 16).ok()
}

/// Same opt-in convention `enrich.rs`'s own `_DEBUG`/`_dbg` uses (touch
/// `~/.cache/winswitch-capture-debug` to enable, `rm` it to disable, zero
/// cost when absent beyond one `exists()` stat per capture): the only way
/// to see, after the fact, whether a given alt-tab open actually used the
/// dmabuf path or silently fell back to wl_shm -- both are invisible to the
/// user otherwise, since a thumbnail looks the same either way.
fn debug_enabled() -> bool {
    std::env::var_os("HOME")
        .map(|h| PathBuf::from(h).join(".cache/winswitch-capture-debug").exists())
        .unwrap_or(false)
}

fn debug_log(msg: &str) {
    if !debug_enabled() {
        return;
    }
    let Some(home) = std::env::var_os("HOME") else { return };
    let path = PathBuf::from(home).join(".cache/winswitch-capture-debug.log");
    let Ok(mut f) = std::fs::OpenOptions::new().create(true).append(true).open(path) else { return };
    use std::io::Write;
    let secs = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0);
    let _ = writeln!(f, "[{secs} pid={}] {msg}", std::process::id());
}

/// The render node backing Hyprland's own primary/compositing GPU, so the
/// GBM buffers this module allocates come from the same device Hyprland
/// renders window content on -- resolved by matching the first entry of
/// Hyprland's own `AQ_DRM_DEVICES` (see `~/.config/hypr/environment.lua`;
/// set via `setenv()` on Hyprland's own live process, which is why it
/// won't show up reading a *running* Hyprland's `/proc/<pid>/environ` --
/// that only ever reflects the environment at the original exec, not later
/// in-process `setenv` calls -- but is inherited correctly by anything
/// Hyprland itself execs afterward, including this binary via its
/// `hl.dsp.exec_cmd` keybind) to its render node via their shared
/// `/sys/class/drm/*/device` PCI directory, rather than hardcoding a vendor
/// or a `renderD1??` number (this machine has both an Intel and an NVIDIA
/// node; picking the wrong one would make every dmabuf buffer allocated
/// here a *foreign* GPU's memory as far as the compositor's copy into it is
/// concerned). Deliberately `None`, not a guessed device, if any step of
/// that resolution fails or `AQ_DRM_DEVICES` isn't set at all -- unlike
/// picking a fallback render node number, "decline dmabuf capture entirely,
/// stay on the always-safe wl_shm path" is a safe failure mode no matter
/// which GPU a wrong guess would have landed on.
fn primary_render_node() -> Option<PathBuf> {
    let devices = std::env::var("AQ_DRM_DEVICES").ok()?;
    let first = devices.split(':').next()?;
    let card_path = std::fs::canonicalize(first).ok()?;
    let card_name = card_path.file_name()?.to_str()?;
    let card_pci = std::fs::canonicalize(format!("/sys/class/drm/{card_name}/device")).ok()?;

    for entry in std::fs::read_dir("/dev/dri").ok()?.flatten() {
        let name = entry.file_name();
        let name = name.to_str()?;
        if !name.starts_with("render") {
            continue;
        }
        let render_pci = std::fs::canonicalize(format!("/sys/class/drm/{name}/device")).ok()?;
        if render_pci == card_pci {
            return Some(entry.path());
        }
    }
    None
}

/// One finished, already-downscaled thumbnail on its way back to the caller
/// -- plain owned RGBA8 data (tightly packed, `width * height * 4` bytes,
/// row-major, no stride padding), for the caller (`main.rs`) to PNG-encode
/// and write out however it likes. This module has no opinion on image
/// format or delivery mechanism.
pub struct ThumbMsg {
    pub index: usize,
    pub width: i32,
    pub height: i32,
    pub rgba: Vec<u8>,
}

/// Accumulates a frame's `buffer`/`linux_dmabuf` offers until `buffer_done`,
/// then whichever path (`try_dmabuf` or `copy_via_shm`) is actually taken
/// ends up filling in its half of the fields below. The shm offer fields
/// are always recorded regardless of which path is chosen, since they
/// double as the fallback bundle if a dmabuf attempt is rejected after the
/// fact (see `Dispatch<ZwpLinuxBufferParamsV1, _>`'s `Failed` arm).
struct PendingFrame {
    index: usize,
    // wl_shm offer + in-flight state.
    width: u32,
    height: u32,
    stride: u32,
    format: Option<wl_shm::Format>,
    mmap: Option<memmap2::MmapMut>,
    buffer: Option<wl_buffer::WlBuffer>,
    pool: Option<wl_shm_pool::WlShmPool>,
    // linux_dmabuf offer (DRM fourcc, width, height) + in-flight state.
    dmabuf_offer: Option<(u32, u32, u32)>,
    dmabuf_bo: Option<BufferObject<()>>,
    dmabuf_buffer: Option<wl_buffer::WlBuffer>,
    // Timing checkpoints -- debug-log-only, see `debug_log` call sites
    // below; never read outside logging.
    t_buffer_done: Option<std::time::Instant>,
    t_created: Option<std::time::Instant>,
}

impl PendingFrame {
    fn new(index: usize) -> Self {
        PendingFrame {
            index,
            width: 0,
            height: 0,
            stride: 0,
            format: None,
            mmap: None,
            buffer: None,
            pool: None,
            dmabuf_offer: None,
            dmabuf_bo: None,
            dmabuf_buffer: None,
            t_buffer_done: None,
            t_created: None,
        }
    }
}

/// User data for a `zwp_linux_buffer_params_v1` object: the export frame
/// it's negotiating a destination buffer for, so `Created`/`Failed` can act
/// on the right `PendingFrame` (keyed by the frame's own `ObjectId`, not
/// the params object's) without a second index lookup.
struct DmabufRequest {
    frame: HyprlandToplevelExportFrameV1,
}

struct Capture {
    shm: Option<wl_shm::WlShm>,
    dmabuf: Option<ZwpLinuxDmabufV1>,
    /// `None` if opening/wrapping the primary render node failed at thread
    /// startup (missing `render` group membership, no DRI device, ...) --
    /// `try_dmabuf` treats that identically to "not viable for this frame"
    /// and every capture just takes the wl_shm path, same as before this
    /// feature existed.
    gbm: Option<GbmDevice<File>>,
    /// (DRM fourcc, modifier) pairs `dmabuf`'s `modifier` events actually
    /// advertised as supported, collected once at startup -- the sole gate
    /// `try_dmabuf` checks before ever allocating a buffer with a given
    /// modifier, so this module can never attempt an import the compositor
    /// didn't already say it could handle (see module doc).
    dmabuf_modifiers: HashSet<(u32, u64)>,
    toplevel_manager: Option<ZwlrForeignToplevelManagerV1>,
    mapping_manager: Option<HyprlandToplevelMappingManagerV1>,
    export_manager: Option<HyprlandToplevelExportManagerV1>,
    address_to_index: HashMap<u64, usize>,
    pending_frames: HashMap<ObjectId, PendingFrame>,
    tx: mpsc::Sender<ThumbMsg>,
}

/// The only sizing knob this module has -- a cap on a thumbnail's long
/// edge, not a target grid cell (this module doesn't know about grid cells
/// at all; the QML frontend fits each PNG into its own cell with
/// `Image.fillMode: PreserveAspectFit`). 320px is comfortably above the
/// largest cell size `ui.rs`'s old `MAX_FRAME` ever used, so nothing here
/// visibly softens compared to before.
const MAX_THUMB_EDGE: u32 = 320;

/// BGRA/BGRX (wl_shm native-endian argb8888/xrgb8888 on a little-endian
/// machine) -> tightly packed RGBA, nearest-neighbor downsampled straight
/// into an aspect-preserving box whose long edge is capped at
/// `MAX_THUMB_EDGE` (see this module's doc comment for why that beats
/// converting at full resolution and resizing after, and why a cap is
/// enough here -- final per-cell fitting is the QML frontend's job, not
/// this module's). A source already smaller than the cap is left at its
/// own size, never upscaled. Returns the chosen `(width, height)` alongside
/// the converted pixels since, unlike the old GTK version, nothing upstream
/// of this module already knows what size it picked.
fn convert_and_downscale(src: &[u8], sw: u32, sh: u32, stride: u32, has_alpha: bool) -> (i32, i32, Vec<u8>) {
    let scale = (MAX_THUMB_EDGE as f64 / sw.max(sh) as f64).min(1.0);
    let tw = ((sw as f64 * scale).round() as i32).max(1);
    let th = ((sh as f64 * scale).round() as i32).max(1);
    let (sw, sh, stride) = (sw as usize, sh as usize, stride as usize);
    let (tw_u, th_u) = (tw as usize, th as usize);

    let mut out = vec![0u8; tw_u * th_u * 4];
    for y in 0..th_u {
        let sy = (y * sh / th_u).min(sh.saturating_sub(1));
        let row = &src[sy * stride..sy * stride + sw * 4];
        let out_row = &mut out[y * tw_u * 4..(y + 1) * tw_u * 4];
        for x in 0..tw_u {
            let sx = (x * sw / tw_u).min(sw.saturating_sub(1));
            let px = &row[sx * 4..sx * 4 + 4];
            let o = &mut out_row[x * 4..x * 4 + 4];
            o[0] = px[2]; // R
            o[1] = px[1]; // G
            o[2] = px[0]; // B
            o[3] = if has_alpha { px[3] } else { 255 };
        }
    }
    (tw, th, out)
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
                "zwp_linux_dmabuf_v1" => {
                    // Bound at v3, not the latest -- v3 still sends the
                    // simple `modifier` event on bind (deprecated but not
                    // removed since v4), which is all `try_dmabuf` needs;
                    // v4's per-surface feedback mechanism is real added
                    // complexity (a format table, tranches, a target
                    // device) this one-shot capture has no use for.
                    state.dmabuf = Some(registry.bind::<ZwpLinuxDmabufV1, _, _>(name, version.min(3), qh, ()));
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
        match event {
            hyprland_toplevel_window_mapping_handle_v1::Event::WindowAddress { address_hi, address } => {
                let addr = ((address_hi as u64) << 32) | address as u64;
                if let Some(&index) = state.address_to_index.get(&addr) {
                    debug_log(&format!("window[{index}]: mapping resolved (addr={addr:#x}), requesting capture"));
                    if let Some(export_manager) = &state.export_manager {
                        export_manager.capture_toplevel_with_wlr_toplevel_handle(0, toplevel, qh, index);
                    }
                } else {
                    debug_log(&format!("mapping resolved to addr={addr:#x}, no matching window in our list"));
                }
            }
            hyprland_toplevel_window_mapping_handle_v1::Event::Failed => {
                debug_log("mapping failed for a toplevel -- leaving its icon placeholder");
            }
        }
    }
}

/// The always-available fallback: build a `wl_shm` pool/buffer from this
/// frame's already-recorded shm offer and copy into it -- the single path
/// this module used before dmabuf capture existed. Called directly from
/// `BufferDone` when the dmabuf path isn't viable at all, and again later
/// (as a recovery) from `Dispatch<ZwpLinuxBufferParamsV1, _>`'s `Failed` arm
/// if a dmabuf attempt was made but the compositor rejected it at runtime.
fn copy_via_shm(state: &mut Capture, frame: &HyprlandToplevelExportFrameV1, qh: &QueueHandle<Capture>) {
    let id = frame.id();
    let Some(shm) = &state.shm else { return };
    let Some(pf) = state.pending_frames.get_mut(&id) else { return };
    let Some(format) = pf.format else { return };
    let size = (pf.stride as u64) * (pf.height as u64);
    let Ok(file) = create_memfd(size) else { return };
    let Ok(mmap) = (unsafe { memmap2::MmapMut::map_mut(&file) }) else { return };
    let pool = shm.create_pool(file.as_fd(), size as i32, qh, ());
    let buffer = pool.create_buffer(0, pf.width as i32, pf.height as i32, pf.stride as i32, format, qh, ());
    frame.copy(&buffer, 1);
    pf.mmap = Some(mmap);
    pf.buffer = Some(buffer);
    pf.pool = Some(pool);
}

/// Attempts the dmabuf path for this frame -- only when a `linux_dmabuf`
/// offer actually arrived, it's a format this module's pixel conversion
/// understands, a GBM device opened successfully at thread startup, *and*
/// the compositor's own dmabuf global already advertised that exact
/// (format, `LINEAR`) pair as supported (see module doc for why that last
/// check is the whole safety story here). Returns `true` once negotiation
/// is under way -- the eventual result (success or a non-fatal `Failed`)
/// arrives later via `Dispatch<ZwpLinuxBufferParamsV1, _>` -- or `false` if
/// nothing was started, meaning the caller should fall back to
/// `copy_via_shm` immediately.
fn try_dmabuf(state: &mut Capture, frame: &HyprlandToplevelExportFrameV1, qh: &QueueHandle<Capture>) -> bool {
    let id = frame.id();
    let Some(dmabuf) = &state.dmabuf else {
        debug_log("try_dmabuf: no zwp_linux_dmabuf_v1 global bound");
        return false;
    };
    let Some(gbm) = &state.gbm else {
        debug_log("try_dmabuf: no gbm device open");
        return false;
    };
    let Some(pf) = state.pending_frames.get(&id) else {
        debug_log("try_dmabuf: no pending_frames entry (unreachable -- BufferDone always follows Buffer)");
        return false;
    };
    let Some((fourcc, width, height)) = pf.dmabuf_offer else {
        debug_log(&format!("window[{}]: try_dmabuf: no linux_dmabuf offer arrived for this frame", pf.index));
        return false;
    };
    let Ok(format) = DrmFormat::try_from(fourcc) else {
        debug_log(&format!("window[{}]: try_dmabuf: unrecognized fourcc {fourcc:#x}", pf.index));
        return false;
    };
    if !matches!(format, DrmFormat::Argb8888 | DrmFormat::Xrgb8888) {
        debug_log(&format!("window[{}]: try_dmabuf: format {format:?} not one this module converts", pf.index));
        return false;
    }
    if !state.dmabuf_modifiers.contains(&(fourcc, u64::from(DrmModifier::Linear))) {
        debug_log(&format!(
            "window[{}]: try_dmabuf: compositor never advertised (format={format:?}, modifier=Linear) as supported",
            pf.index
        ));
        return false;
    }

    let alloc_start = std::time::Instant::now();
    let Ok(bo) = gbm.create_buffer_object_with_modifiers2::<()>(
        width,
        height,
        format,
        std::iter::once(DrmModifier::Linear),
        BufferObjectFlags::RENDERING,
    ) else {
        debug_log(&format!("window[{}]: try_dmabuf: gbm_bo_create_with_modifiers2 failed", pf.index));
        return false;
    };
    let alloc_us = alloc_start.elapsed().as_micros();
    let Ok(bo_fd) = bo.fd() else {
        debug_log(&format!("window[{}]: try_dmabuf: gbm_bo_get_fd failed", pf.index));
        return false;
    };
    let stride = bo.stride();
    let offset = bo.offset(0);
    let modifier: u64 = bo.modifier().into();

    let params = dmabuf.create_params(qh, DmabufRequest { frame: frame.clone() });
    params.add(bo_fd.as_fd(), 0, offset, stride, (modifier >> 32) as u32, modifier as u32);
    params.create(width as i32, height as i32, fourcc, zwp_linux_buffer_params_v1::Flags::empty());

    let Some(pf) = state.pending_frames.get_mut(&id) else { return false };
    debug_log(&format!(
        "window[{}]: dmabuf capture requested (format={format:?}, {width}x{height}, modifier=Linear, gbm_bo_create took {alloc_us}us)",
        pf.index
    ));
    pf.dmabuf_bo = Some(bo);
    true
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
                debug_log(&format!("window[{index}]: wl_shm buffer offered ({width}x{height}, format={format:?})"));
                let pf = state.pending_frames.entry(id).or_insert_with(|| PendingFrame::new(*index));
                pf.width = width;
                pf.height = height;
                pf.stride = stride;
                pf.format = format;
            }
            Event::LinuxDmabuf { format, width, height } => {
                debug_log(&format!("window[{index}]: linux_dmabuf buffer offered ({width}x{height}, format={format:#x})"));
                let pf = state.pending_frames.entry(id).or_insert_with(|| PendingFrame::new(*index));
                pf.dmabuf_offer = Some((format, width, height));
            }
            Event::BufferDone => {
                if let Some(pf) = state.pending_frames.get_mut(&id) {
                    pf.t_buffer_done = Some(std::time::Instant::now());
                }
                if try_dmabuf(state, frame, qh) {
                    return;
                }
                copy_via_shm(state, frame, qh);
            }
            Event::Ready { .. } => {
                if let Some(pf) = state.pending_frames.remove(&id) {
                    let ready_at = std::time::Instant::now();
                    if let Some(bo) = &pf.dmabuf_bo {
                        let has_alpha = matches!(bo.format(), DrmFormat::Argb8888);
                        let (w, h) = (bo.width(), bo.height());
                        let map_start = std::time::Instant::now();
                        let mapped = bo.map(0, 0, w, h, |mapped| convert_and_downscale(mapped.buffer(), w, h, mapped.stride(), has_alpha));
                        let map_us = map_start.elapsed().as_micros();
                        let copy_us = pf.t_created.map(|t| ready_at.duration_since(t).as_micros());
                        let total_us = pf.t_buffer_done.map(|t| ready_at.duration_since(t).as_micros());
                        match &mapped {
                            Ok(_) => debug_log(&format!(
                                "window[{}]: dmabuf capture completed (compositor copy {copy_us:?}us, gbm_bo_map+convert {map_us}us, total since buffer_done {total_us:?}us)",
                                pf.index
                            )),
                            Err(e) => debug_log(&format!("window[{}]: dmabuf gbm_bo_map failed: {e}", pf.index)),
                        }
                        if let Ok((width, height, rgba)) = mapped {
                            let _ = state.tx.send(ThumbMsg { index: pf.index, width, height, rgba });
                        }
                    } else if let (Some(mmap), Some(format)) = (&pf.mmap, pf.format) {
                        let has_alpha = matches!(format, wl_shm::Format::Argb8888);
                        let convert_start = std::time::Instant::now();
                        let (width, height, rgba) = convert_and_downscale(mmap, pf.width, pf.height, pf.stride, has_alpha);
                        let convert_us = convert_start.elapsed().as_micros();
                        let total_us = pf.t_buffer_done.map(|t| ready_at.duration_since(t).as_micros());
                        debug_log(&format!(
                            "window[{}]: wl_shm capture completed (convert {convert_us}us, total since buffer_done {total_us:?}us)",
                            pf.index
                        ));
                        let _ = state.tx.send(ThumbMsg { index: pf.index, width, height, rgba });
                    }
                    if let Some(buffer) = pf.buffer {
                        buffer.destroy();
                    }
                    if let Some(pool) = pf.pool {
                        pool.destroy();
                    }
                    if let Some(dmabuf_buffer) = pf.dmabuf_buffer {
                        dmabuf_buffer.destroy();
                    }
                }
                frame.destroy();
            }
            Event::Failed => {
                if let Some(pf) = state.pending_frames.remove(&id) {
                    if let Some(buffer) = pf.buffer {
                        buffer.destroy();
                    }
                    if let Some(pool) = pf.pool {
                        pool.destroy();
                    }
                    if let Some(dmabuf_buffer) = pf.dmabuf_buffer {
                        dmabuf_buffer.destroy();
                    }
                }
                frame.destroy();
            }
            _ => {}
        }
    }
}

impl Dispatch<ZwpLinuxDmabufV1, ()> for Capture {
    fn event(
        state: &mut Self,
        _proxy: &ZwpLinuxDmabufV1,
        event: zwp_linux_dmabuf_v1::Event,
        _data: &(),
        _conn: &Connection,
        _qh: &QueueHandle<Self>,
    ) {
        // The plain (pre-v3) `format` event carries no modifier info on its
        // own -- not enough to safely request a specific one -- so only
        // `modifier` (bound at v3, sent alongside it) is recorded; anything
        // else here is deliberately ignored.
        if let zwp_linux_dmabuf_v1::Event::Modifier { format, modifier_hi, modifier_lo } = event {
            let modifier = ((modifier_hi as u64) << 32) | modifier_lo as u64;
            state.dmabuf_modifiers.insert((format, modifier));
        }
    }
}

impl Dispatch<ZwpLinuxBufferParamsV1, DmabufRequest> for Capture {
    fn event(
        state: &mut Self,
        proxy: &ZwpLinuxBufferParamsV1,
        event: zwp_linux_buffer_params_v1::Event,
        data: &DmabufRequest,
        _conn: &Connection,
        qh: &QueueHandle<Self>,
    ) {
        use zwp_linux_buffer_params_v1::Event;
        let frame_id = data.frame.id();
        match event {
            Event::Created { buffer } => {
                if let Some(pf) = state.pending_frames.get_mut(&frame_id) {
                    pf.dmabuf_buffer = Some(buffer.clone());
                    let now = std::time::Instant::now();
                    if let Some(t0) = pf.t_buffer_done {
                        debug_log(&format!(
                            "window[{}]: dmabuf buffer created ({}us since buffer_done -- create_params/add/create round trip)",
                            pf.index,
                            now.duration_since(t0).as_micros()
                        ));
                    }
                    pf.t_created = Some(now);
                }
                data.frame.copy(&buffer, 1);
            }
            Event::Failed => {
                // Non-fatal by design (this is exactly why `create` was
                // used instead of `create_immed`) -- the compositor
                // rejected our buffer at runtime despite the advertised
                // (format, modifier) pair matching. Drop the now-unusable
                // GBM buffer and fall back to this same frame's wl_shm
                // offer rather than losing the thumbnail.
                let idx = state.pending_frames.get_mut(&frame_id).map(|pf| {
                    pf.dmabuf_bo = None;
                    pf.index
                });
                debug_log(&format!("window[{idx:?}]: dmabuf buffer import rejected at runtime, falling back to wl_shm"));
                copy_via_shm(state, &data.frame, qh);
            }
        }
        proxy.destroy();
    }

    // `created`'s `buffer` arg is a server-allocated new_id (opcode 0, the
    // first event in the XML) -- without this override, wayland-client's
    // default `event_created_child` panics the first time a `Created`
    // event actually arrives, since it has no way to know what type/
    // user-data to hand that new object without being told explicitly (the
    // exact same reason `ZwlrForeignToplevelManagerV1`'s `Toplevel` event
    // needs one below).
    wayland_client::event_created_child!(Capture, ZwpLinuxBufferParamsV1, [
        0 => (wl_buffer::WlBuffer, ()),
    ]);
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

/// Runs entirely on the background thread `start()` spawns: connects,
/// enumerates/resolves/kicks off captures (the roundtrips), then just keeps
/// dispatching whatever the compositor sends until the connection closes
/// (which for this fire-and-forget process only happens at process exit).
fn run_capture_thread(windows: Vec<Window>, tx: mpsc::Sender<ThumbMsg>) {
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

    // Best-effort: can't resolve the primary GPU, no render-node
    // permission, no DRI device, whatever -- `gbm: None` just means
    // `try_dmabuf` always declines and every capture takes the wl_shm
    // path, exactly as if this feature didn't exist.
    let gbm = match primary_render_node() {
        Some(render_node) => {
            let dev = File::options().read(true).write(true).open(&render_node).ok().and_then(|f| GbmDevice::new(f).ok());
            debug_log(&format!(
                "render node {}: gbm device {}",
                render_node.display(),
                if dev.is_some() { "opened" } else { "open/wrap failed -- dmabuf capture disabled, wl_shm only" }
            ));
            dev
        }
        None => {
            debug_log("couldn't resolve Hyprland's primary GPU render node -- dmabuf capture disabled, wl_shm only");
            None
        }
    };

    let mut state = Capture {
        shm: None,
        dmabuf: None,
        gbm,
        dmabuf_modifiers: HashSet::new(),
        toplevel_manager: None,
        mapping_manager: None,
        export_manager: None,
        address_to_index,
        pending_frames: HashMap::new(),
        tx,
    };

    // registry globals + bind requests, then the bound managers' initial
    // toplevel-enumeration events (and the dmabuf global's own `modifier`
    // events, a direct response to its bind with no further dependency),
    // then the address-mapping events that enumeration triggers -- each
    // step's requests only go out once the previous roundtrip flushes, so
    // this has to be three, not one. Blocking here is fine -- this whole
    // function runs on its own dedicated thread.
    debug_log(&format!("starting: {} windows, {} addresses parsed", windows.len(), state.address_to_index.len()));
    for i in 0..3 {
        if event_queue.roundtrip(&mut state).is_err() {
            debug_log(&format!("roundtrip {i} errored, aborting"));
            return;
        }
    }
    debug_log(&format!(
        "after 3 roundtrips: shm={} export_manager={} toplevel_manager={} mapping_manager={} dmabuf={} dmabuf_modifiers={}",
        state.shm.is_some(),
        state.export_manager.is_some(),
        state.toplevel_manager.is_some(),
        state.mapping_manager.is_some(),
        state.dmabuf.is_some(),
        state.dmabuf_modifiers.len()
    ));

    // Frame negotiation + copy (which can take a moment per window) streams
    // in over however many further events the compositor sends; nothing
    // left to do but keep blocking on the socket for them; an `Err` means
    // the connection's gone (compositor restarted, or -- unreachably, since
    // nothing else holds this thread open -- our own process is exiting).
    loop {
        if event_queue.blocking_dispatch(&mut state).is_err() {
            return;
        }
    }
}

/// Kicks off live thumbnail capture for `windows` on a background thread and
/// returns immediately, handing back the receiving end of the channel
/// finished thumbnails stream in on (in no particular order -- captures
/// resolve whenever the compositor gets to them, see `wayland_capture.rs`'s
/// module doc). A window's `index` in `windows` never arrives more than
/// once, and may not arrive at all if its mapping or capture fails; the
/// caller drains the receiver however suits it (`main.rs` prints an NDJSON
/// line per message, bounded by an overall deadline rather than waiting for
/// every window since a handful failing shouldn't hang the whole process).
pub fn start(windows: &[Window]) -> mpsc::Receiver<ThumbMsg> {
    let windows_owned = windows.to_vec();
    let (tx, rx) = mpsc::channel::<ThumbMsg>();
    std::thread::spawn(move || run_capture_thread(windows_owned, tx));
    rx
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::protocol::hyprland_toplevel_export_v1::hyprland_toplevel_export_frame_v1::Event as FrameEvent;

    /// Minimal, print-only state for `manual_check_dmabuf_offer` -- captures
    /// one real toplevel and logs every buffer-type event the frame object
    /// sends, without ever completing a copy (no `wl_shm` pool/buffer setup,
    /// unlike the real `Capture`/`PendingFrame` machinery above). All this
    /// needs to answer is "does the compositor offer a `linux_dmabuf` buffer
    /// alongside (or instead of) the `wl_shm` one we currently always take."
    struct ProbeState {
        mapping_manager: Option<HyprlandToplevelMappingManagerV1>,
        export_manager: Option<HyprlandToplevelExportManagerV1>,
        target_addr: u64,
        requested: bool,
        done: bool,
    }

    impl Dispatch<wl_registry::WlRegistry, ()> for ProbeState {
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
                    "zwlr_foreign_toplevel_manager_v1" => {
                        registry.bind::<ZwlrForeignToplevelManagerV1, _, _>(name, version.min(3), qh, ());
                    }
                    "hyprland_toplevel_mapping_manager_v1" => {
                        state.mapping_manager =
                            Some(registry.bind::<HyprlandToplevelMappingManagerV1, _, _>(name, version.min(1), qh, ()));
                    }
                    "hyprland_toplevel_export_manager_v1" => {
                        state.export_manager =
                            Some(registry.bind::<HyprlandToplevelExportManagerV1, _, _>(name, version.min(2), qh, ()));
                    }
                    _ => {}
                }
            }
        }
    }

    impl Dispatch<ZwlrForeignToplevelManagerV1, ()> for ProbeState {
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

        wayland_client::event_created_child!(ProbeState, ZwlrForeignToplevelManagerV1, [
            0 => (ZwlrForeignToplevelHandleV1, ()),
        ]);
    }

    impl Dispatch<ZwlrForeignToplevelHandleV1, ()> for ProbeState {
        fn event(_: &mut Self, _: &ZwlrForeignToplevelHandleV1, _: <ZwlrForeignToplevelHandleV1 as Proxy>::Event, _: &(), _: &Connection, _: &QueueHandle<Self>) {}
    }

    impl Dispatch<HyprlandToplevelMappingManagerV1, ()> for ProbeState {
        fn event(_: &mut Self, _: &HyprlandToplevelMappingManagerV1, _: <HyprlandToplevelMappingManagerV1 as Proxy>::Event, _: &(), _: &Connection, _: &QueueHandle<Self>) {}
    }

    impl Dispatch<HyprlandToplevelExportManagerV1, ()> for ProbeState {
        fn event(_: &mut Self, _: &HyprlandToplevelExportManagerV1, _: <HyprlandToplevelExportManagerV1 as Proxy>::Event, _: &(), _: &Connection, _: &QueueHandle<Self>) {}
    }

    impl Dispatch<HyprlandToplevelWindowMappingHandleV1, ZwlrForeignToplevelHandleV1> for ProbeState {
        fn event(
            state: &mut Self,
            _proxy: &HyprlandToplevelWindowMappingHandleV1,
            event: hyprland_toplevel_window_mapping_handle_v1::Event,
            toplevel: &ZwlrForeignToplevelHandleV1,
            _conn: &Connection,
            qh: &QueueHandle<Self>,
        ) {
            if state.requested {
                return;
            }
            if let hyprland_toplevel_window_mapping_handle_v1::Event::WindowAddress { address_hi, address } = event {
                let addr = ((address_hi as u64) << 32) | address as u64;
                if addr == state.target_addr {
                    if let Some(export_manager) = &state.export_manager {
                        state.requested = true;
                        export_manager.capture_toplevel_with_wlr_toplevel_handle(0, toplevel, qh, ());
                    }
                }
            }
        }
    }

    impl Dispatch<HyprlandToplevelExportFrameV1, ()> for ProbeState {
        fn event(
            state: &mut Self,
            _frame: &HyprlandToplevelExportFrameV1,
            event: FrameEvent,
            _data: &(),
            _conn: &Connection,
            _qh: &QueueHandle<Self>,
        ) {
            match event {
                FrameEvent::Buffer { format, width, height, stride } => {
                    println!("wl_shm buffer offered: {width}x{height} stride={stride} format={format:?}");
                }
                FrameEvent::LinuxDmabuf { format, width, height } => {
                    println!("linux_dmabuf buffer offered: {width}x{height} format=0x{format:08x}");
                }
                FrameEvent::BufferDone => {
                    println!("buffer_done (every buffer type has been enumerated above)");
                    state.done = true;
                }
                FrameEvent::Failed => {
                    println!("capture failed");
                    state.done = true;
                }
                other => println!("other event: {other:?}"),
            }
        }
    }

    /// Not a unit test -- connects to this machine's real, currently-running
    /// Hyprland/Wayland session and captures one real open window, purely to
    /// observe which buffer type(s) `hyprland-toplevel-export-v1` actually
    /// offers on `buffer_done`: `wl_shm` only (what `wayland_capture.rs`
    /// currently always takes -- a GPU->CPU readback per window, per
    /// alt-tab open) or also `linux_dmabuf` (a GPU buffer handle, importable
    /// as a texture with no CPU readback at all -- the optimization worth
    /// pursuing if it's actually offered on this Hyprland build). Never
    /// sends `copy` -- this only needs the `buffer`/`linux_dmabuf` offers,
    /// not a completed frame. `#[ignore]`d for the same reason
    /// `enrich.rs::manual_enrichment_check` is: it depends on real desktop
    /// state (at least one open window) rather than being a hermetic unit
    /// test. Run with:
    ///   cargo test --release manual_check_dmabuf_offer -- --ignored --nocapture
    #[test]
    #[ignore]
    fn manual_check_dmabuf_offer() {
        let windows = crate::hyprctl::list_windows();
        assert!(!windows.is_empty(), "need at least one open window to probe a capture against");
        let target_addr = parse_address(&windows[0].address).expect("window address should parse as hex");
        println!("probing capture of window[0]: {} ({})", windows[0].title, windows[0].address);

        let conn = Connection::connect_to_env().expect("connect to the running Wayland/Hyprland session");
        let mut event_queue = conn.new_event_queue();
        let qh = event_queue.handle();
        let display = conn.display();
        let _registry = display.get_registry(&qh, ());

        let mut state = ProbeState {
            mapping_manager: None,
            export_manager: None,
            target_addr,
            requested: false,
            done: false,
        };

        // registry -> bind, toplevel enumeration -> mapping requests,
        // mapping resolution -> our capture_toplevel request -- same
        // three-roundtrip shape as the real `start()`.
        for _ in 0..3 {
            event_queue.roundtrip(&mut state).expect("roundtrip");
        }
        assert!(state.requested, "never resolved window[0]'s address to a toplevel handle -- can't probe capture");

        // A few more blocking dispatches to receive the buffer offer(s) and
        // buffer_done; bounded so a compositor that never responds can't
        // hang the test forever.
        for _ in 0..20 {
            if state.done {
                break;
            }
            event_queue.blocking_dispatch(&mut state).expect("dispatch");
        }
        assert!(state.done, "never received buffer_done -- compositor didn't respond to the capture request");
    }

    /// Not a unit test -- runs the real, unmodified `run_capture_thread`
    /// (the exact function `start()` spawns for a live alt-tab open)
    /// against every window actually open on this machine right now, and
    /// asserts real thumbnails come back. Unlike `manual_check_dmabuf_offer`
    /// above (which only checks what's *offered*), this exercises the whole
    /// pipeline end to end -- GBM allocation, the `zwp_linux_dmabuf_v1`
    /// negotiation, `gbm_bo_map` readback, and the wl_shm fallback path --
    /// through whichever branch the real code actually takes, with no
    /// test-only stand-in for any of it. Turns on this module's own
    /// opt-in debug log around the run so the printed summary says whether
    /// dmabuf actually carried any of these captures or every one fell
    /// back to wl_shm (both are legitimate outcomes -- what this test
    /// guards against is a capture producing zero thumbnails, or panicking,
    /// not which path was taken). `#[ignore]`d for the same live-state
    /// reason `manual_enrichment_check`/`manual_check_dmabuf_offer` are.
    /// Run with:
    ///   cargo test --release manual_check_real_capture_end_to_end -- --ignored --nocapture
    #[test]
    #[ignore]
    fn manual_check_real_capture_end_to_end() {
        let home = std::env::var("HOME").expect("HOME must be set");
        let flag_path = PathBuf::from(&home).join(".cache/winswitch-capture-debug");
        let log_path = PathBuf::from(&home).join(".cache/winswitch-capture-debug.log");
        std::fs::write(&flag_path, b"").expect("touch debug flag");
        let _ = std::fs::remove_file(&log_path); // start each run's log clean

        let windows = crate::hyprctl::list_windows();
        assert!(!windows.is_empty(), "need at least one open window to capture");
        let window_count = windows.len();
        println!("capturing {window_count} real open windows end-to-end");

        let (tx, rx) = mpsc::channel::<ThumbMsg>();
        std::thread::spawn(move || run_capture_thread(windows, tx));

        let mut received = 0;
        let deadline = std::time::Instant::now() + Duration::from_secs(15);
        while std::time::Instant::now() < deadline {
            match rx.recv_timeout(Duration::from_millis(500)) {
                Ok(msg) => {
                    received += 1;
                    println!("thumbnail: window[{}] {}x{} ({} bytes)", msg.index, msg.width, msg.height, msg.rgba.len());
                    assert!(msg.width > 0 && msg.height > 0, "zero-sized thumbnail for window[{}]", msg.index);
                    assert_eq!(
                        msg.rgba.len(),
                        (msg.width as usize) * (msg.height as usize) * 4,
                        "rgba buffer size doesn't match its own reported dimensions for window[{}]",
                        msg.index
                    );
                }
                Err(mpsc::RecvTimeoutError::Timeout) => break,
                Err(mpsc::RecvTimeoutError::Disconnected) => break,
            }
        }
        let _ = std::fs::remove_file(&flag_path); // don't leave logging on

        let log = std::fs::read_to_string(&log_path).unwrap_or_default();
        println!("--- capture debug log ---");
        for line in log.lines() {
            println!("{line}");
        }
        println!("--------------------------");
        println!(
            "summary: {received}/{window_count} thumbnails; dmabuf requested={}, dmabuf completed={}, fell back to wl_shm={}",
            log.matches("dmabuf capture requested").count(),
            log.matches("dmabuf capture completed").count(),
            log.matches("falling back to wl_shm").count() + log.matches("dmabuf gbm_bo_map failed").count(),
        );

        assert!(received > 0, "captured zero thumbnails out of {window_count} open windows");
    }
}
