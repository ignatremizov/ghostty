const std = @import("std");
const ids = @import("workspace_ids.zig");
const model = @import("workspace_model.zig");
const restore = @import("workspace_restore.zig");
const snapshot = @import("workspace_snapshot.zig");

const split_aware_splits = [_]snapshot.SplitRecord{
    .{
        .split_id = ids.SplitId.init(20),
        .window_id = ids.WindowId.init(10),
        .ordinal = 1,
        .root_layout_node_id = "split-20-root",
    },
    .{
        .split_id = ids.SplitId.init(19),
        .window_id = ids.WindowId.init(9),
        .ordinal = 0,
        .root_layout_node_id = "split-19-root",
    },
};

const split_aware_tabs = [_]snapshot.TabRecord{
    .{
        .tab_id = ids.TabId.init(8),
        .ordinal = 2,
        .title_override = "logs",
    },
    .{
        .tab_id = ids.TabId.init(7),
        .ordinal = 1,
        .title_override = "editor",
    },
    .{
        .tab_id = ids.TabId.init(5),
        .ordinal = 0,
        .title_override = "shell",
    },
};

const split_aware_root_8_children = [_][]const u8{"tab-8-leaf"};
const split_aware_root_7_children = [_][]const u8{"tab-7-leaf"};
const split_aware_root_5_children = [_][]const u8{"tab-5-split"};
const split_aware_tab_5_split_children = [_][]const u8{ "tab-5-left", "tab-5-right" };
const split_aware_workspace_children = [_][]const u8{ "split-19-root", "split-20-root" };
const split_aware_split_20_children = [_][]const u8{"tab-8-root"};
const split_aware_split_19_children = [_][]const u8{ "tab-7-root", "tab-5-root" };
const split_aware_layout = [_]snapshot.LayoutNodeRecord{
    .{
        .layout_node_id = "workspace-root",
        .node_type = .split,
        .split_direction = .right,
        .child_ids = &split_aware_workspace_children,
    },
    .{
        .layout_node_id = "split-20-root",
        .tab_id = ids.TabId.init(8),
        .node_type = .split_root,
        .child_ids = &split_aware_split_20_children,
    },
    .{
        .layout_node_id = "tab-8-root",
        .tab_id = ids.TabId.init(8),
        .node_type = .tab_root,
        .child_ids = &split_aware_root_8_children,
    },
    .{
        .layout_node_id = "tab-8-leaf",
        .tab_id = ids.TabId.init(8),
        .node_type = .session_leaf,
        .session_id = ids.SessionId.init(44),
    },
    .{
        .layout_node_id = "split-19-root",
        .tab_id = ids.TabId.init(7),
        .node_type = .split_root,
        .child_ids = &split_aware_split_19_children,
    },
    .{
        .layout_node_id = "tab-7-root",
        .tab_id = ids.TabId.init(7),
        .node_type = .tab_root,
        .child_ids = &split_aware_root_7_children,
    },
    .{
        .layout_node_id = "tab-7-leaf",
        .tab_id = ids.TabId.init(7),
        .node_type = .session_leaf,
        .session_id = ids.SessionId.init(43),
    },
    .{
        .layout_node_id = "tab-5-root",
        .tab_id = ids.TabId.init(5),
        .node_type = .tab_root,
        .child_ids = &split_aware_root_5_children,
        .is_selected = true,
    },
    .{
        .layout_node_id = "tab-5-split",
        .tab_id = ids.TabId.init(5),
        .node_type = .split,
        .split_direction = .right,
        .child_ids = &split_aware_tab_5_split_children,
    },
    .{
        .layout_node_id = "tab-5-left",
        .tab_id = ids.TabId.init(5),
        .node_type = .session_leaf,
        .session_id = ids.SessionId.init(41),
    },
    .{
        .layout_node_id = "tab-5-right",
        .tab_id = ids.TabId.init(5),
        .node_type = .session_leaf,
        .session_id = ids.SessionId.init(42),
        .is_selected = true,
    },
};

const split_aware_sessions = [_]snapshot.SessionRecord{
    .{
        .session_id = ids.SessionId.init(44),
        .tab_id = ids.TabId.init(8),
        .cwd = "/home/ignat/code/logs",
        .command = .{ .shell = "tail -f build.log" },
    },
    .{
        .session_id = ids.SessionId.init(43),
        .tab_id = ids.TabId.init(7),
        .cwd = "/home/ignat/code/specs",
        .command = .{ .shell = "zsh" },
    },
    .{
        .session_id = ids.SessionId.init(42),
        .tab_id = ids.TabId.init(5),
        .cwd = "/home/ignat/code/ghostty",
        .command = .{ .argv = &.{ "zig", "build" } },
        .focus_preferred = true,
    },
    .{
        .session_id = ids.SessionId.init(41),
        .tab_id = ids.TabId.init(5),
        .cwd = "/home/ignat/code/ghostty",
        .command = .{ .shell = "nvim" },
    },
};

fn buildSplitAwareSnapshot() snapshot.Snapshot {
    return .{
        .snapshot_id = ids.SnapshotId.init(11),
        .saved_at = "2026-03-22T12:00:00Z",
        .workspace = .{
            .workspace_id = ids.WorkspaceId.init(3),
            .workspace_key = "client-a",
            .name = "client-a",
            .layout_root_node_id = "workspace-root",
            .selected_window_id = ids.WindowId.init(9),
            .selected_split_id = ids.SplitId.init(19),
            .selected_tab_id = ids.TabId.init(5),
            .selected_session_id = ids.SessionId.init(42),
        },
        .splits = &split_aware_splits,
        .tabs = &split_aware_tabs,
        .layout = &split_aware_layout,
        .sessions = &split_aware_sessions,
        .restore_results = null,
    };
}

test "restore planner builds first-class split replay order with multiple tabs per split" {
    const testing = std.testing;

    const plan = try restore.planAlloc(testing.allocator, buildSplitAwareSnapshot());
    defer plan.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 2), plan.splits.len);
    try testing.expectEqual(ids.SplitId.init(19), plan.splits[0].split_id);
    try testing.expectEqual(@as(usize, 0), plan.splits[0].tab_start);
    try testing.expectEqual(@as(usize, 2), plan.splits[0].tab_len);
    try testing.expectEqual(ids.WindowId.init(9), plan.splits[0].preferred_window_id.?);
    try testing.expect(plan.splits[0].selected_hint);
    try testing.expectEqualStrings("split-19-root", plan.splits[0].layout_root_id.?);

    try testing.expectEqual(ids.SplitId.init(20), plan.splits[1].split_id);
    try testing.expectEqual(@as(usize, 2), plan.splits[1].tab_start);
    try testing.expectEqual(@as(usize, 1), plan.splits[1].tab_len);

    try testing.expectEqual(@as(usize, 3), plan.tabs.len);
    try testing.expectEqual(ids.SplitId.init(19), plan.tabs[0].split_id);
    try testing.expectEqual(ids.TabId.init(5), plan.tabs[0].tab_id);
    try testing.expectEqual(@as(usize, 0), plan.tabs[0].ordinal_in_split);
    try testing.expectEqual(@as(usize, 2), plan.tabs[0].session_len);
    try testing.expect(plan.tabs[0].selected_hint);
    try testing.expectEqual(ids.TabId.init(7), plan.tabs[1].tab_id);
    try testing.expectEqual(@as(usize, 1), plan.tabs[1].ordinal_in_split);
    try testing.expectEqual(ids.SplitId.init(20), plan.tabs[2].split_id);
    try testing.expectEqual(ids.TabId.init(8), plan.tabs[2].tab_id);

    try testing.expectEqual(@as(usize, 4), plan.sessions.len);
    try testing.expectEqual(ids.SplitId.init(19), plan.sessions[0].split_id);
    try testing.expectEqual(ids.SessionId.init(41), plan.sessions[0].session_id);
    try testing.expectEqual(@as(usize, 0), plan.sessions[0].session_ordinal);
    try testing.expectEqual(ids.SessionId.init(42), plan.sessions[1].session_id);
    try testing.expectEqual(@as(usize, 1), plan.sessions[1].session_ordinal);
    try testing.expect(plan.sessions[1].focus_preferred);
    try testing.expectEqual(ids.SessionId.init(43), plan.sessions[2].session_id);
    try testing.expectEqual(ids.SplitId.init(20), plan.sessions[3].split_id);
    try testing.expectEqual(ids.SessionId.init(44), plan.sessions[3].session_id);
    try testing.expectEqual(restore.SurfaceAction.realize_replacement_surface, plan.sessions[0].surface_action);
    try testing.expectEqual(restore.ScrollbackPolicy.do_not_restore, plan.sessions[0].scrollback_policy);
}

test "restore finalizer keeps split-aware restored and failed sessions in plan order" {
    const testing = std.testing;

    const plan = try restore.planAlloc(testing.allocator, buildSplitAwareSnapshot());
    defer plan.deinit(testing.allocator);

    const finalized = try restore.finalizeAlloc(testing.allocator, &plan, &.{
        .{ .restored = .{
            .session_id = ids.SessionId.init(44),
            .window_id = ids.WindowId.init(10),
            .split_id = ids.SplitId.init(20),
            .tab_id = ids.TabId.init(8),
        } },
        .{ .restored = .{
            .session_id = ids.SessionId.init(43),
            .window_id = ids.WindowId.init(9),
            .split_id = ids.SplitId.init(19),
            .tab_id = ids.TabId.init(7),
        } },
        .{ .failed = .{
            .session_id = ids.SessionId.init(42),
            .code = .cwd_missing,
        } },
        .{ .restored = .{
            .session_id = ids.SessionId.init(41),
            .window_id = ids.WindowId.init(9),
            .split_id = ids.SplitId.init(19),
            .tab_id = ids.TabId.init(5),
        } },
    });
    defer finalized.deinit(testing.allocator);

    try testing.expectEqualSlices(
        ids.SessionId,
        &.{ ids.SessionId.init(41), ids.SessionId.init(43), ids.SessionId.init(44) },
        finalized.results.restored_session_ids,
    );
    try testing.expectEqual(@as(usize, 1), finalized.results.failed_sessions.len);
    try testing.expectEqualStrings("cwd_missing", finalized.results.failed_sessions[0].code);
    try testing.expectEqualStrings("working directory no longer exists", finalized.results.failed_sessions[0].message);
    try testing.expectEqual(ids.WindowId.init(9), finalized.selection.window_id.?);
    try testing.expectEqual(ids.SplitId.init(19), finalized.selection.split_id.?);
    try testing.expectEqual(ids.TabId.init(5), finalized.selection.tab_id.?);
    try testing.expectEqual(ids.SessionId.init(41), finalized.selection.session_id.?);
    try testing.expectEqual(model.SelectionFallbackReason.selected_session_missing, finalized.selection.fallback_reason.?);
}

test "restore selection fallback stays inside the selected window when a split is missing" {
    const testing = std.testing;

    var value = buildSplitAwareSnapshot();
    value.workspace.selected_split_id = ids.SplitId.init(19);
    value.workspace.selected_tab_id = ids.TabId.init(7);
    value.workspace.selected_session_id = ids.SessionId.init(43);

    const plan = try restore.planAlloc(testing.allocator, value);
    defer plan.deinit(testing.allocator);

    const finalized = try restore.finalizeAlloc(testing.allocator, &plan, &.{
        .{ .restored = .{
            .session_id = ids.SessionId.init(41),
            .window_id = ids.WindowId.init(9),
            .split_id = ids.SplitId.init(21),
            .tab_id = ids.TabId.init(5),
        } },
        .{ .failed = .{
            .session_id = ids.SessionId.init(42),
            .code = .replacement_surface_failed,
        } },
        .{ .failed = .{
            .session_id = ids.SessionId.init(43),
            .code = .command_missing,
        } },
        .{ .restored = .{
            .session_id = ids.SessionId.init(44),
            .window_id = ids.WindowId.init(10),
            .split_id = ids.SplitId.init(20),
            .tab_id = ids.TabId.init(8),
        } },
    });
    defer finalized.deinit(testing.allocator);

    try testing.expectEqual(ids.WindowId.init(9), finalized.selection.window_id.?);
    try testing.expectEqual(ids.SplitId.init(21), finalized.selection.split_id.?);
    try testing.expectEqual(ids.TabId.init(5), finalized.selection.tab_id.?);
    try testing.expectEqual(ids.SessionId.init(41), finalized.selection.session_id.?);
    try testing.expectEqual(model.SelectionFallbackReason.selected_split_missing, finalized.selection.fallback_reason.?);
    try testing.expectEqualStrings("selected_split_missing", finalized.results.selection_fallback.?.reason);
}
