const std = @import("std");
const Allocator = std.mem.Allocator;
const workspace = @import("workspace.zig");

pub const Options = workspace.OpenOptions;

/// Open an existing workspace in the running Ghostty instance, or create it
/// when `--create` is supplied, and print the JSON workspace-control response.
pub fn run(alloc: Allocator) !u8 {
    return workspace.runOpen(alloc);
}
