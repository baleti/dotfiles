//! Trimmed down to just what wayland_capture.rs actually reads (`address`)
//! -- see ~/.config/hypr/winswitch/src/hyprctl.rs for the full struct
//! (class/title/workspace/pid/size) that crate's own UI layer needs; the
//! claude-usage daemon already resolves the target address itself (tty/pid
//! correlation against `hyprctl clients -j`), so this binary is only ever
//! handed one address on the command line, never a window list to filter.

pub struct Window {
    pub address: String,
}
