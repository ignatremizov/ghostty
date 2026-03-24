// The required comptime API for any apprt.
pub const App = @import("gtk/App.zig");
pub const Surface = @import("gtk/Surface.zig");
pub const resourcesDir = @import("gtk/flatpak.zig").resourcesDir;

// The exported API, custom for the apprt.
pub const class = @import("gtk/class.zig");
pub const WeakRef = @import("gtk/weak_ref.zig").WeakRef;
pub const pre_exec = @import("gtk/pre_exec.zig");
pub const post_fork = @import("gtk/post_fork.zig");
pub const workspace_ids = @import("gtk/workspace_ids.zig");
pub const workspace_registry = @import("gtk/workspace_registry.zig");
pub const workspace_model = @import("gtk/workspace_model.zig");
pub const workspace_attention = @import("gtk/workspace_attention.zig");
pub const workspace_control = @import("gtk/workspace_control.zig");

test {
    @import("std").testing.refAllDecls(@This());
    _ = @import("gtk/ext.zig");
    _ = @import("gtk/key.zig");
    _ = @import("gtk/portal.zig");
}
