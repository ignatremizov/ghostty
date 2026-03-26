const std = @import("std");
const gio = @import("gio");
const glib = @import("glib");

const internal_os = @import("../../os/main.zig");
const workspace_control = @import("workspace_control.zig");
const workspace_ids = @import("workspace_ids.zig");
const workspace_snapshot = @import("workspace_snapshot.zig");
const workspace_storage = @import("workspace_storage.zig");

fn stringVariant(value: []const u8) *glib.Variant {
    return glib.ext.Variant.newFrom(value);
}

fn buildSnapshot() workspace_snapshot.Snapshot {
    const split_children = [_][]const u8{"tab-root-1"};
    const tab_children = [_][]const u8{"leaf-1"};
    const argv = [_][]const u8{"sh"};

    return .{
        .snapshot_id = workspace_ids.SnapshotId.init(1),
        .saved_at = "2026-03-25T12:00:00Z",
        .workspace = .{
            .workspace_id = workspace_ids.WorkspaceId.init(1),
            .workspace_key = "workspace-key-1",
            .name = "Developer Workspace",
            .layout_root_node_id = "split-root-1",
            .selected_window_id = workspace_ids.WindowId.init(1),
            .selected_split_id = workspace_ids.SplitId.init(1),
            .selected_tab_id = workspace_ids.TabId.init(1),
            .selected_session_id = workspace_ids.SessionId.init(1),
        },
        .splits = &.{.{
            .split_id = workspace_ids.SplitId.init(1),
            .window_id = workspace_ids.WindowId.init(1),
            .ordinal = 0,
            .root_layout_node_id = "split-root-1",
        }},
        .tabs = &.{.{
            .tab_id = workspace_ids.TabId.init(1),
            .ordinal = 0,
            .title_override = "shell",
        }},
        .layout = &.{
            .{
                .layout_node_id = "split-root-1",
                .tab_id = workspace_ids.TabId.init(1),
                .node_type = .split_root,
                .child_ids = split_children[0..],
            },
            .{
                .layout_node_id = "tab-root-1",
                .tab_id = workspace_ids.TabId.init(1),
                .node_type = .tab_root,
                .child_ids = tab_children[0..],
            },
            .{
                .layout_node_id = "leaf-1",
                .tab_id = workspace_ids.TabId.init(1),
                .node_type = .session_leaf,
                .session_id = workspace_ids.SessionId.init(1),
            },
        },
        .sessions = &.{.{
            .session_id = workspace_ids.SessionId.init(1),
            .tab_id = workspace_ids.TabId.init(1),
            .cwd = "/tmp",
            .command = .{ .argv = argv[0..] },
            .title_override = "shell",
            .focus_preferred = true,
        }},
    };
}

fn withStateHome(
    alloc: std.mem.Allocator,
    dir: []const u8,
    body: *const fn () anyerror!void,
) !void {
    const saved = blk: {
        const value = std.posix.getenv("XDG_STATE_HOME") orelse break :blk null;
        break :blk try alloc.dupeZ(u8, value);
    };
    defer env_restore: {
        const value = saved orelse {
            _ = internal_os.unsetenv("XDG_STATE_HOME");
            break :env_restore;
        };
        _ = internal_os.setenv("XDG_STATE_HOME", value);
        alloc.free(value);
    }

    const dir_z = try alloc.dupeZ(u8, dir);
    defer alloc.free(dir_z);
    _ = internal_os.setenv("XDG_STATE_HOME", dir_z);
    try body();
}

test "ipc workspace control encodes stable request envelope" {
    const testing = std.testing;

    const encoded = try workspace_control.encodeRequestAlloc(
        testing.allocator,
        "req-1",
        .workspace_list,
        "{}",
    );
    defer testing.allocator.free(encoded);

    try testing.expect(std.mem.indexOf(u8, encoded, "\"id\":\"req-1\"") != null);
    try testing.expect(std.mem.indexOf(u8, encoded, "\"method\":\"workspace.list\"") != null);
    try testing.expect(std.mem.indexOf(u8, encoded, "\"params\":{}") != null);
}

test "ipc workspace control returns workspace list response" {
    const testing = std.testing;

    const request = try workspace_control.encodeRequestAlloc(
        testing.allocator,
        "req-2",
        .workspace_list,
        "{}",
    );
    defer testing.allocator.free(request);

    const result = try workspace_control.dispatchAlloc(testing.allocator, request);
    defer testing.allocator.free(result.response_json);

    try testing.expectEqual(workspace_control.Method.workspace_list, result.metadata.method.?);
    try testing.expectEqual(workspace_control.FocusBehavior.no_focus_change, result.metadata.focus_behavior);
    try testing.expect(std.mem.indexOf(u8, result.response_json, "\"ok\":true") != null);
    try testing.expect(std.mem.indexOf(u8, result.response_json, "\"workspaces\":[]") != null);
}

test "ipc workspace control rejects unsupported methods with request id" {
    const testing = std.testing;

    const result = try workspace_control.dispatchAlloc(
        testing.allocator,
        "{\"id\":\"req-3\",\"method\":\"workspace.delete\",\"params\":{}}",
    );
    defer testing.allocator.free(result.response_json);

    try testing.expectEqual(@as(?workspace_control.Method, null), result.metadata.method);
    try testing.expect(std.mem.indexOf(u8, result.response_json, "\"id\":\"req-3\"") != null);
    try testing.expect(std.mem.indexOf(u8, result.response_json, "\"code\":\"invalid_method\"") != null);
}

test "ipc workspace control validates session split params before dispatch" {
    const testing = std.testing;

    const invalid_direction = try workspace_control.dispatchAlloc(
        testing.allocator,
        "{\"id\":\"req-4\",\"method\":\"session.split\",\"params\":{\"session\":\"session:2\",\"direction\":\"sideways\"}}",
    );
    defer testing.allocator.free(invalid_direction.response_json);

    try testing.expectEqual(workspace_control.Method.session_split, invalid_direction.metadata.method.?);
    try testing.expectEqual(workspace_control.FocusBehavior.no_focus_change, invalid_direction.metadata.focus_behavior);
    try testing.expect(std.mem.indexOf(u8, invalid_direction.response_json, "\"code\":\"invalid_params\"") != null);
}

test "ipc workspace control marks mutating workspace actions as focus-changing" {
    const testing = std.testing;

    try testing.expectEqual(workspace_control.FocusBehavior.may_change_focus, workspace_control.Method.workspace_open.focusBehavior());
    try testing.expectEqual(workspace_control.FocusBehavior.no_focus_change, workspace_control.Method.workspace_restore.focusBehavior());
    try testing.expectEqual(workspace_control.FocusBehavior.may_change_focus, workspace_control.Method.session_split.focusBehavior());
    try testing.expectEqual(workspace_control.FocusBehavior.may_change_focus, workspace_control.Method.session_close.focusBehavior());
    try testing.expectEqual(workspace_control.FocusBehavior.may_change_focus, workspace_control.Method.session_focus.focusBehavior());
}

test "ipc workspace control action parameter decodes variant strings" {
    const testing = std.testing;

    const request = try workspace_control.encodeRequestAlloc(
        testing.allocator,
        null,
        .session_list,
        "{\"workspace\":\"workspace:1\"}",
    );
    defer testing.allocator.free(request);

    const variant = stringVariant(request);
    defer variant.unref();

    const result = try workspace_control.dispatchActionParameterAlloc(testing.allocator, variant);
    defer testing.allocator.free(result.response_json);

    try testing.expectEqual(workspace_control.Method.session_list, result.metadata.method.?);
    try testing.expect(std.mem.indexOf(u8, result.response_json, "\"sessions\":[]") != null);
}

test "ipc workspace control restore reports not found for unknown target" {
    const testing = std.testing;

    const result = try workspace_control.dispatchAlloc(
        testing.allocator,
        "{\"id\":\"req-r0\",\"method\":\"workspace.restore\",\"params\":{\"workspace\":\"missing-workspace\"}}",
    );
    defer testing.allocator.free(result.response_json);

    try testing.expectEqual(workspace_control.Method.workspace_restore, result.metadata.method.?);
    try testing.expect(std.mem.indexOf(u8, result.response_json, "\"code\":\"not_found\"") != null);
}

test "ipc workspace control save reports not ready without a window" {
    const testing = std.testing;

    const result = try workspace_control.dispatchAlloc(
        testing.allocator,
        "{\"id\":\"req-s0\",\"method\":\"workspace.save\",\"params\":{\"workspace\":\"ghostty\"}}",
    );
    defer testing.allocator.free(result.response_json);

    try testing.expectEqual(workspace_control.Method.workspace_save, result.metadata.method.?);
    try testing.expect(std.mem.indexOf(u8, result.response_json, "\"code\":\"not_ready\"") != null);
}

test "ipc workspace control restore validates stored snapshots before replay" {
    const testing = std.testing;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const state_home = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(state_home);

    try tmp.dir.makePath("ghostty/workspaces");
    var workspace_dir = try tmp.dir.openDir("ghostty/workspaces", .{});
    defer workspace_dir.close();

    const storage = workspace_storage.Storage.init(testing.allocator, workspace_dir);
    const filename = try storage.writeCheckpoint(buildSnapshot());
    defer testing.allocator.free(filename);

    try withStateHome(testing.allocator, state_home, &struct {
        fn run() !void {
            const result = try workspace_control.dispatchAlloc(
                std.testing.allocator,
                "{\"id\":\"req-r1\",\"method\":\"workspace.restore\",\"params\":{\"workspace\":\"workspace-key-1\"}}",
            );
            defer std.testing.allocator.free(result.response_json);

            try std.testing.expectEqual(workspace_control.Method.workspace_restore, result.metadata.method.?);
            try std.testing.expect(std.mem.indexOf(u8, result.response_json, "\"code\":\"not_supported\"") != null);
        }
    }.run);
}

test "ipc workspace control restore rejects invalid stored snapshots" {
    const testing = std.testing;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const state_home = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(state_home);

    try tmp.dir.makePath("ghostty/workspaces");
    var workspace_dir = try tmp.dir.openDir("ghostty/workspaces", .{});
    defer workspace_dir.close();

    const invalid_snapshot_json =
        \\{
        \\  "version": 1,
        \\  "snapshot_id": "snapshot-1",
        \\  "saved_at": "2026-03-25T12:00:00Z",
        \\  "workspace": {
        \\    "workspace_id": "workspace-1",
        \\    "workspace_key": "workspace-key-1",
        \\    "name": "Broken Workspace",
        \\    "selected_window_id": "window-1",
        \\    "selected_split_id": "split-1",
        \\    "selected_tab_id": "tab-1",
        \\    "selected_session_id": "session-1"
        \\  },
        \\  "splits": [],
        \\  "tabs": [],
        \\  "layout": [],
        \\  "sessions": []
        \\}
    ;
    const catalog_json =
        \\{
        \\  "version": 1,
        \\  "entries": [
        \\    {
        \\      "snapshot_id": "snapshot-1",
        \\      "workspace_id": "workspace-1",
        \\      "workspace_key": "workspace-key-1",
        \\      "workspace_name": "Broken Workspace",
        \\      "saved_at": "2026-03-25T12:00:00Z",
        \\      "path": "snapshot-1.json"
        \\    }
        \\  ]
        \\}
    ;

    {
        const file = try workspace_dir.createFile("snapshot-1.json", .{ .truncate = true });
        defer file.close();
        try file.writeAll(invalid_snapshot_json);
    }
    {
        const file = try workspace_dir.createFile(workspace_storage.Storage.catalog_filename, .{ .truncate = true });
        defer file.close();
        try file.writeAll(catalog_json);
    }

    try withStateHome(testing.allocator, state_home, &struct {
        fn run() !void {
            const result = try workspace_control.dispatchAlloc(
                std.testing.allocator,
                "{\"id\":\"req-r2\",\"method\":\"workspace.restore\",\"params\":{\"workspace\":\"workspace-key-1\"}}",
            );
            defer std.testing.allocator.free(result.response_json);

            try std.testing.expectEqual(workspace_control.Method.workspace_restore, result.metadata.method.?);
            try std.testing.expect(std.mem.indexOf(u8, result.response_json, "\"code\":\"restore_invalid\"") != null);
        }
    }.run);
}

test "ipc workspace control updates action state with caller-visible JSON" {
    const testing = std.testing;

    const request = try workspace_control.encodeRequestAlloc(
        testing.allocator,
        "req-5",
        .workspace_list,
        "{}",
    );
    defer testing.allocator.free(request);

    const action = workspace_control.createAction();
    defer action.unref();

    const parameter = stringVariant(request);
    defer parameter.unref();

    const result = try workspace_control.updateActionStateAlloc(
        testing.allocator,
        action,
        parameter,
    );
    defer testing.allocator.free(result.response_json);

    const state = action.as(gio.Action).getState().?;
    defer state.unref();

    const decoded = try workspace_control.decodeActionStateAlloc(testing.allocator, state);
    defer testing.allocator.free(decoded);

    try testing.expectEqual(workspace_control.Method.workspace_list, result.metadata.method.?);
    try testing.expectEqualStrings(result.response_json, decoded);
}
