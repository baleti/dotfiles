//! Generated bindings for the Wayland extensions phase 4 talks to directly,
//! from the XML files vendored in `protocols/` (fetched from
//! hyprwm/hyprland-protocols and swaywm/wlr-protocols, plus the
//! ext-foreign-toplevel-list-v1 staging protocol copied from this system's
//! wayland-protocols package -- needed only because
//! hyprland-toplevel-mapping-v1.xml's `get_window_for_toplevel` request
//! references its handle type, even though we only ever call the `_wlr`
//! sibling request).
//!
//! The `wayland_protocol_client!` macro below (and the two-step
//! generate_interfaces!-then-generate_client_code! dance inside it) is
//! copied from Smithay/wayland-rs's own `wayland-protocols-wlr` crate's
//! `protocol_macro.rs` (trimmed to client-only, no server/cfg-feature
//! split) -- that crate is the reference implementation for vendoring
//! third-party Wayland protocol XMLs against wayland-scanner 0.31, and
//! reproducing its exact module shape (each protocol gets its own isolated
//! `__interfaces` submodule; naive flat or single-shared-scope invocations
//! collide on wayland-scanner's internal helper items).
#![allow(non_upper_case_globals, non_camel_case_types, unused_imports)]

macro_rules! wayland_protocol_client {
    ($path:expr, [$($imports:path),*]) => {
        pub mod __interfaces {
            use wayland_client::protocol::__interfaces::*;
            $(use $imports::{__interfaces::*};)*
            wayland_scanner::generate_interfaces!($path);
        }
        use self::__interfaces::*;
        use wayland_client;
        use wayland_client::protocol::*;
        $(use $imports::*;)*
        wayland_scanner::generate_client_code!($path);
    };
}

pub mod ext_foreign_toplevel_list_v1 {
    wayland_protocol_client!("./protocols/ext-foreign-toplevel-list-v1.xml", []);
}

pub mod wlr_foreign_toplevel_management_unstable_v1 {
    wayland_protocol_client!(
        "./protocols/wlr-foreign-toplevel-management-unstable-v1.xml",
        []
    );
}

pub mod hyprland_toplevel_mapping_v1 {
    // Absolute paths, not `super::...` -- the latter resolves relative to
    // where each `$imports` token is *spliced into* the macro body (nested
    // inside an inner `__interfaces` submodule), not this call site, so a
    // relative path silently means the wrong thing here.
    wayland_protocol_client!(
        "./protocols/hyprland-toplevel-mapping-v1.xml",
        [
            crate::protocol::ext_foreign_toplevel_list_v1,
            crate::protocol::wlr_foreign_toplevel_management_unstable_v1
        ]
    );
}

pub mod hyprland_toplevel_export_v1 {
    wayland_protocol_client!(
        "./protocols/hyprland-toplevel-export-v1.xml",
        [crate::protocol::wlr_foreign_toplevel_management_unstable_v1]
    );
}
