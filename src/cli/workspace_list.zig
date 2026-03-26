const std = @import("std");
const Allocator = std.mem.Allocator;
const workspace = @import("workspace.zig");

pub const Options = workspace.ListOptions;

/// Query the running Ghostty instance for its visible and restorable
/// workspaces and print the JSON workspace-control response.
pub fn run(alloc: Allocator) !u8 {
    return workspace.runList(alloc);
}
