const std = @import("std");
const ids = @import("workspace_ids.zig");
const model = @import("workspace_model.zig");
const registry_mod = @import("workspace_registry.zig");

const SessionRow = struct {
    session_id: ids.SessionId,
    window_id: ids.WindowId,
    split_id: ids.SplitId,
    tab_id: ids.TabId,
    selected: bool,
};

const SidebarRowKind = enum {
    window,
    split,
    tab,
    layout_split,
    session,
};

const SidebarRow = struct {
    kind: SidebarRowKind,
    window_id: ?ids.WindowId = null,
    split_id: ?ids.SplitId = null,
    tab_id: ?ids.TabId = null,
    session_id: ?ids.SessionId = null,
    depth: usize = 0,
    selected: bool = false,
    attached: bool = false,
};

fn seedRuntime(
    alloc: std.mem.Allocator,
    runtime: *registry_mod.WorkspaceRuntime,
    window_ids: []const ids.WindowId,
    split_ids: []const ids.SplitId,
    tab_ids: []const ids.TabId,
    session_ids: []const ids.SessionId,
) !void {
    std.debug.assert(window_ids.len == split_ids.len);
    std.debug.assert(split_ids.len == tab_ids.len);
    std.debug.assert(tab_ids.len == session_ids.len);
    const runtime_alloc = runtime.runtimeAllocator();

    var workspace_split_ids = std.ArrayList(ids.SplitId).empty;
    defer workspace_split_ids.deinit(alloc);
    for (split_ids) |split_id| {
        if (!containsSplitId(workspace_split_ids.items, split_id)) {
            try workspace_split_ids.append(alloc, split_id);
        }
    }

    runtime.workspace.split_ids = try runtime_alloc.dupe(ids.SplitId, workspace_split_ids.items);
    runtime.workspace.tab_ids = tab_ids;
    runtime.workspace.session_ids = session_ids;

    for (window_ids, 0..) |window_id, index| {
        if (!containsWindowId(runtime.windows.items, window_id)) {
            var window_split_ids = std.ArrayList(ids.SplitId).empty;
            defer window_split_ids.deinit(alloc);
            for (window_ids, 0..) |candidate_window_id, candidate_index| {
                if (candidate_window_id != window_id) continue;
                if (!containsSplitId(window_split_ids.items, split_ids[candidate_index])) {
                    try window_split_ids.append(alloc, split_ids[candidate_index]);
                }
            }
            try runtime.windows.append(alloc, .{
                .window_id = window_id,
                .workspace_id = runtime.workspace.workspace_id,
                .is_active = index == 0,
                .is_quick_terminal = false,
                .split_ids = try runtime_alloc.dupe(ids.SplitId, window_split_ids.items),
                .last_presented_at = null,
            });
        }
    }

    for (workspace_split_ids.items, 0..) |split_id, split_index| {
        const split_root = try std.fmt.allocPrint(runtime_alloc, "split-root-{d}", .{split_id.raw()});
        var split_tab_ids = std.ArrayList(ids.TabId).empty;
        defer split_tab_ids.deinit(alloc);
        var split_tab_roots = std.ArrayList([]const u8).empty;
        defer split_tab_roots.deinit(alloc);
        var split_window_id: ?ids.WindowId = null;

        for (split_ids, 0..) |candidate_split_id, index| {
            if (candidate_split_id != split_id) continue;
            if (split_window_id == null) split_window_id = window_ids[index];
            try split_tab_ids.append(alloc, tab_ids[index]);
            try split_tab_roots.append(alloc, try std.fmt.allocPrint(runtime_alloc, "tab-root-{d}", .{tab_ids[index].raw()}));
        }

        try runtime.splits.append(alloc, .{
            .split_id = split_id,
            .workspace_id = runtime.workspace.workspace_id,
            .window_id = split_window_id.?,
            .title = "Workspace Split",
            .ordinal = split_index,
            .tab_ids = try runtime_alloc.dupe(ids.TabId, split_tab_ids.items),
            .layout_root_id = split_root,
        });
        try runtime.layout.append(alloc, .{
            .layout_node_id = split_root,
            .workspace_id = runtime.workspace.workspace_id,
            .split_id = split_id,
            .node_type = .split_root,
            .child_ids = try runtime_alloc.dupe([]const u8, split_tab_roots.items),
            .is_selected = split_index == 0,
        });
    }

    for (window_ids, 0..) |window_id, index| {
        const tab_root = try std.fmt.allocPrint(runtime_alloc, "tab-root-{d}", .{tab_ids[index].raw()});
        const leaf_layout = try std.fmt.allocPrint(runtime_alloc, "tab-leaf-{d}", .{session_ids[index].raw()});

        try runtime.tabs.append(alloc, .{
            .tab_id = tab_ids[index],
            .split_id = split_ids[index],
            .workspace_id = runtime.workspace.workspace_id,
            .window_id = window_id,
            .title = if (index == 0) "shell" else "editor",
            .layout_root_id = tab_root,
            .ordinal = index,
        });

        try runtime.layout.append(alloc, .{
            .layout_node_id = tab_root,
            .workspace_id = runtime.workspace.workspace_id,
            .split_id = split_ids[index],
            .tab_id = tab_ids[index],
            .node_type = .tab,
            .child_ids = try runtime_alloc.dupe([]const u8, &.{leaf_layout}),
            .is_selected = index == 0,
        });
        try runtime.layout.append(alloc, .{
            .layout_node_id = leaf_layout,
            .workspace_id = runtime.workspace.workspace_id,
            .split_id = split_ids[index],
            .tab_id = tab_ids[index],
            .node_type = .session_leaf,
            .session_id = session_ids[index],
            .is_selected = index == 0,
        });

        try runtime.sessions.append(alloc, .{
            .session_id = session_ids[index],
            .workspace_id = runtime.workspace.workspace_id,
            .window_id = window_id,
            .tab_id = tab_ids[index],
            .split_id = split_ids[index],
            .layout_node_id = leaf_layout,
            .title = if (index == 0) "shell" else "editor",
            .cwd = if (index == 0) "/home/ignat/code/ghostty" else "/home/ignat/code/specs",
            .command = .{ .shell = "zsh" },
            .focus_state = if (index == 0) .focused else .background,
        });

        try runtime.surfaces.append(alloc, .{
            .surface_id = ids.SurfaceId.init(100 + @as(u64, index)),
            .session_id = session_ids[index],
            .tab_id = tab_ids[index],
            .split_id = split_ids[index],
            .window_id = window_id,
            .is_realized = true,
        });
    }
}

fn containsSplitId(items: []const ids.SplitId, needle: ids.SplitId) bool {
    for (items) |item| {
        if (item == needle) return true;
    }
    return false;
}

fn containsWindowId(items: []const model.WindowRuntime, needle: ids.WindowId) bool {
    for (items) |item| {
        if (item.window_id == needle) return true;
    }
    return false;
}

fn listSessions(
    alloc: std.mem.Allocator,
    runtime: *const registry_mod.WorkspaceRuntime,
) ![]SessionRow {
    var rows = std.ArrayList(SessionRow).empty;
    errdefer rows.deinit(alloc);

    for (runtime.sessions.items) |session| {
        try rows.append(alloc, .{
            .session_id = session.session_id,
            .window_id = session.window_id,
            .split_id = session.split_id,
            .tab_id = session.tab_id,
            .selected = runtime.workspace.selected_session_id != null and runtime.workspace.selected_session_id.? == session.session_id,
        });
    }

    return rows.toOwnedSlice(alloc);
}

fn listSidebarRows(
    alloc: std.mem.Allocator,
    runtime: *const registry_mod.WorkspaceRuntime,
    current_window_id: ids.WindowId,
) ![]SidebarRow {
    const Collector = struct {
        alloc: std.mem.Allocator,
        rows: std.ArrayList(SidebarRow),

        pub fn visitWindow(self: *@This(), window_id: ids.WindowId, _: bool) void {
            self.rows.append(self.alloc, .{
                .kind = .window,
                .window_id = window_id,
            }) catch @panic("oom");
        }

        pub fn visitSplit(
            self: *@This(),
            split: *const model.SplitRuntime,
            depth: usize,
            selected: bool,
        ) void {
            self.rows.append(self.alloc, .{
                .kind = .split,
                .split_id = split.split_id,
                .depth = depth,
                .selected = selected,
            }) catch @panic("oom");
        }

        pub fn visitTab(
            self: *@This(),
            tab: *const model.TabRuntime,
            depth: usize,
            selected: bool,
        ) void {
            self.rows.append(self.alloc, .{
                .kind = .tab,
                .tab_id = tab.tab_id,
                .depth = depth,
                .selected = selected,
            }) catch @panic("oom");
        }

        pub fn visitLayoutSplit(
            self: *@This(),
            _: ?model.SplitDirection,
            depth: usize,
        ) void {
            self.rows.append(self.alloc, .{
                .kind = .layout_split,
                .depth = depth,
            }) catch @panic("oom");
        }

        pub fn visitSession(
            self: *@This(),
            session: *const model.Session,
            _: usize,
            selected: bool,
            attached: bool,
            depth: usize,
        ) void {
            self.rows.append(self.alloc, .{
                .kind = .session,
                .window_id = session.window_id,
                .split_id = session.split_id,
                .tab_id = session.tab_id,
                .session_id = session.session_id,
                .depth = depth,
                .selected = selected,
                .attached = attached,
            }) catch @panic("oom");
        }
    };

    var collector: Collector = .{
        .alloc = alloc,
        .rows = std.ArrayList(SidebarRow).empty,
    };
    errdefer collector.rows.deinit(alloc);

    registry_mod.visitSidebarRows(runtime, current_window_id, &collector);
    return collector.rows.toOwnedSlice(alloc);
}

test "workspace registry runtime models pane-host splits owning one tab each" {
    const testing = std.testing;

    var registry = registry_mod.Registry.init(testing.allocator);
    defer registry.deinit();

    const entry = try registry.createWorkspace("client-a", "client-a", "2026-03-22T00:00:00Z");

    try seedRuntime(
        testing.allocator,
        entry,
        &.{ ids.WindowId.init(1), ids.WindowId.init(1) },
        &.{ ids.SplitId.init(11), ids.SplitId.init(12) },
        &.{ ids.TabId.init(21), ids.TabId.init(22) },
        &.{ ids.SessionId.init(31), ids.SessionId.init(32) },
    );

    try testing.expectEqual(@as(usize, 2), entry.splits.items.len);
    try testing.expectEqual(@as(usize, 1), entry.splits.items[0].tab_ids.len);
    try testing.expectEqual(ids.TabId.init(21), entry.splits.items[0].tab_ids[0]);
    try testing.expectEqual(@as(usize, 1), entry.splits.items[1].tab_ids.len);
    try testing.expectEqual(ids.TabId.init(22), entry.splits.items[1].tab_ids[0]);

    const split_root = entry.layout.items[0];
    try testing.expectEqual(model.NodeType.split_root, split_root.node_type);
    try testing.expectEqual(@as(usize, 1), split_root.child_ids.len);
    try testing.expectEqualStrings(entry.tabs.items[0].layout_root_id, split_root.child_ids[0]);

    const second_split_root = entry.layout.items[1];
    try testing.expectEqual(model.NodeType.split_root, second_split_root.node_type);
    try testing.expectEqual(@as(usize, 1), second_split_root.child_ids.len);
    try testing.expectEqualStrings(entry.tabs.items[1].layout_root_id, second_split_root.child_ids[0]);
}

test "workspace registry preserves workspace listing order" {
    const testing = std.testing;

    var registry = registry_mod.Registry.init(testing.allocator);
    defer registry.deinit();

    const alpha = try registry.createWorkspace("alpha", "alpha", "2026-03-22T00:00:00Z");
    const alpha_id = alpha.workspace.workspace_id;
    const bravo = try registry.createWorkspace("bravo", "bravo", "2026-03-22T00:00:00Z");
    const bravo_id = bravo.workspace.workspace_id;

    try testing.expectEqual(alpha_id, registry.workspaces.items[0].workspace.workspace_id);
    try testing.expectEqual(bravo_id, registry.workspaces.items[1].workspace.workspace_id);
    try testing.expectEqualStrings("alpha", registry.findWorkspace(alpha_id).?.workspace.name);
    try testing.expectEqualStrings("bravo", registry.findWorkspace(bravo_id).?.workspace.name);
}

test "workspace registry lists sessions across windows and keeps selection as routing hints" {
    const testing = std.testing;

    var registry = registry_mod.Registry.init(testing.allocator);
    defer registry.deinit();

    const entry = try registry.createWorkspace("client-a", "client-a", "2026-03-22T00:00:00Z");
    const workspace_id = entry.workspace.workspace_id;

    const window_ids = [_]ids.WindowId{ ids.WindowId.init(1), ids.WindowId.init(1), ids.WindowId.init(2) };
    const split_ids = [_]ids.SplitId{ ids.SplitId.init(11), ids.SplitId.init(12), ids.SplitId.init(13) };
    const tab_ids = [_]ids.TabId{ ids.TabId.init(21), ids.TabId.init(22), ids.TabId.init(23) };
    const session_ids = [_]ids.SessionId{ ids.SessionId.init(31), ids.SessionId.init(32), ids.SessionId.init(33) };

    try seedRuntime(
        testing.allocator,
        entry,
        window_ids[0..],
        split_ids[0..],
        tab_ids[0..],
        session_ids[0..],
    );

    try registry.updateSelection(workspace_id, .{
        .selected_window_id = window_ids[2],
        .selected_split_id = split_ids[2],
        .selected_tab_id = tab_ids[2],
        .selected_session_id = session_ids[2],
    });

    try entry.workspace.validateSelection();

    const rows = try listSessions(testing.allocator, entry);
    defer testing.allocator.free(rows);

    try testing.expectEqual(@as(usize, 3), rows.len);
    try testing.expectEqual(session_ids[0], rows[0].session_id);
    try testing.expectEqual(window_ids[0], rows[0].window_id);
    try testing.expect(!rows[0].selected);

    try testing.expectEqual(session_ids[1], rows[1].session_id);
    try testing.expectEqual(window_ids[1], rows[1].window_id);
    try testing.expect(!rows[1].selected);

    try testing.expectEqual(session_ids[2], rows[2].session_id);
    try testing.expectEqual(window_ids[2], rows[2].window_id);
    try testing.expect(rows[2].selected);

    try testing.expectEqual(window_ids[2], entry.workspace.selected_window_id.?);
    try testing.expectEqual(split_ids[2], entry.workspace.selected_split_id.?);
    try testing.expectEqual(tab_ids[2], entry.workspace.selected_tab_id.?);
    try testing.expectEqual(session_ids[2], entry.workspace.selected_session_id.?);
    try testing.expectEqual(model.FocusState.focused, entry.sessions.items[2].focus_state);
    try testing.expect(entry.sessions.items[0].focus_state != .focused);

    try testing.expectEqualSlices(ids.SplitId, entry.workspace.split_ids, &.{ ids.SplitId.init(11), ids.SplitId.init(12), ids.SplitId.init(13) });
    try testing.expectEqualSlices(ids.TabId, entry.workspace.tab_ids, tab_ids[0..]);
    try testing.expectEqualSlices(ids.SessionId, entry.workspace.session_ids, session_ids[0..]);
    try testing.expectEqual(@as(usize, 3), entry.sessions.items.len);
    try testing.expectEqual(@as(usize, 2), entry.windows.items.len);
}

test "workspace registry rejects invalid selection routing chains" {
    const testing = std.testing;

    var registry = registry_mod.Registry.init(testing.allocator);
    defer registry.deinit();

    const entry = try registry.createWorkspace("client-a", "client-a", "2026-03-22T00:00:00Z");
    const workspace_id = entry.workspace.workspace_id;

    const window_ids = [_]ids.WindowId{ ids.WindowId.init(1), ids.WindowId.init(2) };
    const split_ids = [_]ids.SplitId{ ids.SplitId.init(11), ids.SplitId.init(12) };
    const tab_ids = [_]ids.TabId{ ids.TabId.init(21), ids.TabId.init(22) };
    const session_ids = [_]ids.SessionId{ ids.SessionId.init(31), ids.SessionId.init(32) };

    try seedRuntime(
        testing.allocator,
        entry,
        window_ids[0..],
        split_ids[0..],
        tab_ids[0..],
        session_ids[0..],
    );

    try registry.updateSelection(workspace_id, .{
        .selected_window_id = window_ids[0],
        .selected_split_id = split_ids[0],
        .selected_tab_id = tab_ids[0],
        .selected_session_id = session_ids[0],
    });

    try registry.updateSelection(workspace_id, .{
        .selected_window_id = window_ids[0],
        .selected_split_id = split_ids[1],
    });
    try testing.expectEqual(window_ids[0], entry.workspace.selected_window_id.?);
    try testing.expectEqual(split_ids[1], entry.workspace.selected_split_id.?);
    try testing.expect(entry.workspace.selected_tab_id == null);
    try testing.expect(entry.workspace.selected_session_id == null);

    try registry.updateSelection(workspace_id, .{
        .selected_window_id = window_ids[0],
        .selected_split_id = split_ids[0],
        .selected_tab_id = tab_ids[0],
        .selected_session_id = session_ids[0],
    });
    try testing.expectError(error.SelectedTabOutsideSplit, registry.updateSelection(workspace_id, .{
        .selected_window_id = window_ids[1],
        .selected_split_id = split_ids[1],
        .selected_tab_id = tab_ids[0],
    }));
    try testing.expectError(error.SelectedSessionOutsideTab, registry.updateSelection(workspace_id, .{
        .selected_window_id = window_ids[1],
        .selected_split_id = split_ids[1],
        .selected_tab_id = tab_ids[1],
        .selected_session_id = session_ids[0],
    }));
    try testing.expectError(error.SelectedSessionNotFound, registry.updateSelection(workspace_id, .{
        .selected_window_id = window_ids[0],
        .selected_split_id = split_ids[0],
        .selected_tab_id = tab_ids[0],
        .selected_session_id = ids.SessionId.init(999),
    }));

    try testing.expectEqual(window_ids[0], entry.workspace.selected_window_id.?);
    try testing.expectEqual(split_ids[0], entry.workspace.selected_split_id.?);
    try testing.expectEqual(tab_ids[0], entry.workspace.selected_tab_id.?);
    try testing.expectEqual(session_ids[0], entry.workspace.selected_session_id.?);
    try testing.expectEqual(model.FocusState.focused, entry.sessions.items[0].focus_state);
    try testing.expect(entry.sessions.items[1].focus_state != .focused);
}

test "workspace registry sidebar rows include sessions from every window in one logical workspace" {
    const testing = std.testing;

    var registry = registry_mod.Registry.init(testing.allocator);
    defer registry.deinit();

    const entry = try registry.createWorkspace("client-a", "client-a", "2026-03-22T00:00:00Z");
    const workspace_id = entry.workspace.workspace_id;

    const window_ids = [_]ids.WindowId{ ids.WindowId.init(1), ids.WindowId.init(2) };
    const split_ids = [_]ids.SplitId{ ids.SplitId.init(11), ids.SplitId.init(12) };
    const tab_ids = [_]ids.TabId{ ids.TabId.init(21), ids.TabId.init(22) };
    const session_ids = [_]ids.SessionId{ ids.SessionId.init(31), ids.SessionId.init(32) };

    try seedRuntime(
        testing.allocator,
        entry,
        window_ids[0..],
        split_ids[0..],
        tab_ids[0..],
        session_ids[0..],
    );

    try registry.updateSelection(workspace_id, .{
        .selected_window_id = window_ids[1],
        .selected_split_id = split_ids[1],
        .selected_tab_id = tab_ids[1],
        .selected_session_id = session_ids[1],
    });

    const counts = registry_mod.sidebarCounts(entry);
    try testing.expectEqual(@as(usize, 2), counts.windows);
    try testing.expectEqual(@as(usize, 2), counts.splits);
    try testing.expectEqual(@as(usize, 2), counts.tabs);
    try testing.expectEqual(@as(usize, 2), counts.sessions);

    const rows = try listSidebarRows(testing.allocator, entry, window_ids[0]);
    defer testing.allocator.free(rows);

    try testing.expectEqual(@as(usize, 8), rows.len);
    try testing.expectEqual(SidebarRowKind.window, rows[0].kind);
    try testing.expectEqual(window_ids[0], rows[0].window_id.?);
    try testing.expectEqual(SidebarRowKind.session, rows[3].kind);
    try testing.expectEqual(session_ids[0], rows[3].session_id.?);
    try testing.expect(!rows[3].selected);
    try testing.expectEqual(SidebarRowKind.window, rows[4].kind);
    try testing.expectEqual(window_ids[1], rows[4].window_id.?);
    try testing.expectEqual(SidebarRowKind.session, rows[7].kind);
    try testing.expectEqual(session_ids[1], rows[7].session_id.?);
    try testing.expect(rows[7].selected);
    try testing.expectEqual(window_ids[1], rows[7].window_id.?);
}

test "workspace registry keeps unattached sessions selectable" {
    const testing = std.testing;

    var registry = registry_mod.Registry.init(testing.allocator);
    defer registry.deinit();

    const entry = try registry.createWorkspace("client-a", "client-a", "2026-03-22T00:00:00Z");
    const workspace_id = entry.workspace.workspace_id;

    try seedRuntime(
        testing.allocator,
        entry,
        &.{ids.WindowId.init(1)},
        &.{ids.SplitId.init(11)},
        &.{ids.TabId.init(21)},
        &.{ids.SessionId.init(31)},
    );
    entry.surfaces.items.len = 0;

    try registry.updateSelection(workspace_id, .{
        .selected_window_id = ids.WindowId.init(1),
        .selected_split_id = ids.SplitId.init(11),
        .selected_tab_id = ids.TabId.init(21),
        .selected_session_id = ids.SessionId.init(31),
    });

    try testing.expectEqual(ids.SessionId.init(31), entry.workspace.selected_session_id.?);
    try testing.expectEqual(model.FocusState.focused, entry.sessions.items[0].focus_state);
    try testing.expectEqual(@as(usize, 0), entry.surfaces.items.len);
}
