const std = @import("std");
const Allocator = std.mem.Allocator;
const workspace = @import("workspace.zig");

pub const Options = workspace.FocusSessionOptions;

/// Focus a target session in the running Ghostty instance and print the JSON
/// workspace-control response.
pub fn run(alloc: Allocator) !u8 {
    return workspace.runFocusSession(alloc);
}
