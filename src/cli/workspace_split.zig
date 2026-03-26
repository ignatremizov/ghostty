const std = @import("std");
const Allocator = std.mem.Allocator;
const workspace = @import("workspace.zig");

pub const Options = workspace.SplitOptions;

/// Create a Ghostty-native split from a target session and print the JSON
/// workspace-control response.
pub fn run(alloc: Allocator) !u8 {
    return workspace.runSplit(alloc);
}
