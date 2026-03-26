const std = @import("std");
const Allocator = std.mem.Allocator;
const workspace = @import("workspace.zig");

pub const Options = workspace.ListSessionsOptions;

/// List sessions for a workspace, or for the currently selected workspace
/// when `--workspace` is omitted, and print the JSON response.
pub fn run(alloc: Allocator) !u8 {
    return workspace.runListSessions(alloc);
}
