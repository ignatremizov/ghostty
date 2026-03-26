const std = @import("std");
const Allocator = std.mem.Allocator;
const workspace = @import("workspace.zig");

pub const Options = workspace.SaveOptions;

/// Save the current live snapshot for a workspace in the running Ghostty
/// instance and print the JSON workspace-control response.
pub fn run(alloc: Allocator) !u8 {
    return workspace.runSave(alloc);
}
