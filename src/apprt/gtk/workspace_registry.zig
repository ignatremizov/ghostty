const std = @import("std");
const ids = @import("workspace_ids.zig");
const model = @import("workspace_model.zig");

pub const WorkspaceSelection = struct {
    selected_window_id: ?ids.WindowId = null,
    selected_split_id: ?ids.SplitId = null,
    selected_tab_id: ?ids.TabId = null,
    selected_session_id: ?ids.SessionId = null,

    pub fn validate(self: WorkspaceSelection) !void {
        if (self.selected_session_id != null and self.selected_tab_id == null) {
            return error.SelectedSessionRequiresTab;
        }
        if (self.selected_tab_id != null and self.selected_split_id == null) {
            return error.SelectedTabRequiresSplit;
        }
        if (self.selected_split_id != null and self.selected_window_id == null) {
            return error.SelectedSplitRequiresWindow;
        }
    }
};

pub const WorkspaceRuntime = struct {
    workspace: model.Workspace,
    runtime_arena: std.heap.ArenaAllocator,
    windows: std.ArrayListUnmanaged(model.WindowRuntime) = .empty,
    splits: std.ArrayListUnmanaged(model.SplitRuntime) = .empty,
    tabs: std.ArrayListUnmanaged(model.TabRuntime) = .empty,
    layout: std.ArrayListUnmanaged(model.LayoutNode) = .empty,
    sessions: std.ArrayListUnmanaged(model.Session) = .empty,
    surfaces: std.ArrayListUnmanaged(model.SurfaceRuntime) = .empty,

    pub fn runtimeAllocator(self: *WorkspaceRuntime) std.mem.Allocator {
        return self.runtime_arena.allocator();
    }

    pub fn resetRuntime(self: *WorkspaceRuntime) void {
        _ = self.runtime_arena.reset(.retain_capacity);
        self.workspace.split_ids = &.{};
        self.workspace.session_ids = &.{};
        self.workspace.tab_ids = &.{};
        self.windows.items.len = 0;
        self.splits.items.len = 0;
        self.tabs.items.len = 0;
        self.layout.items.len = 0;
        self.sessions.items.len = 0;
        self.surfaces.items.len = 0;
    }

    pub fn deinit(self: *WorkspaceRuntime, alloc: std.mem.Allocator) void {
        alloc.free(self.workspace.name);
        alloc.free(self.workspace.slug);
        alloc.free(self.workspace.created_at);
        alloc.free(self.workspace.updated_at);
        if (self.workspace.snapshot_ref) |snapshot_ref| {
            alloc.free(snapshot_ref.saved_at);
            alloc.free(snapshot_ref.path);
        }
        self.runtime_arena.deinit();
        self.windows.deinit(alloc);
        self.splits.deinit(alloc);
        self.tabs.deinit(alloc);
        self.layout.deinit(alloc);
        self.sessions.deinit(alloc);
        self.surfaces.deinit(alloc);
    }
};

pub const SidebarCounts = struct {
    windows: usize,
    splits: usize,
    tabs: usize,
    sessions: usize,
};

pub fn sidebarCounts(runtime: *const WorkspaceRuntime) SidebarCounts {
    return .{
        .windows = runtime.windows.items.len,
        .splits = runtime.splits.items.len,
        .tabs = runtime.tabs.items.len,
        .sessions = runtime.sessions.items.len,
    };
}

pub fn visitSidebarRows(
    runtime: *const WorkspaceRuntime,
    current_window_id: ids.WindowId,
    visitor: anytype,
) void {
    const counts = sidebarCounts(runtime);
    if (counts.sessions == 0) return;

    for (runtime.windows.items) |window| {
        if (counts.windows > 1) {
            visitor.visitWindow(window.window_id, window.window_id == current_window_id);
        }

        for (window.split_ids) |split_id| {
            const split = findSplit(runtime, split_id) orelse continue;
            visitor.visitSplit(
                split,
                0,
                runtime.workspace.selected_split_id != null and runtime.workspace.selected_split_id.? == split.split_id,
            );

            for (split.tab_ids) |tab_id| {
                const tab = findTab(runtime, tab_id) orelse continue;
                visitor.visitTab(
                    tab,
                    1,
                    runtime.workspace.selected_tab_id != null and runtime.workspace.selected_tab_id.? == tab.tab_id,
                );

                var session_index: usize = 0;
                visitSidebarLayoutChildren(
                    runtime,
                    tab.layout_root_id,
                    2,
                    &session_index,
                    visitor,
                );
            }
        }
    }
}

pub const SessionIdentityIndex = struct {
    allocator: std.mem.Allocator,
    path_to_session: std.StringHashMap(ids.SessionId),
    session_to_path: std.AutoHashMap(ids.SessionId, []const u8),
    attachment_to_session: std.AutoHashMap(usize, ids.SessionId),

    pub fn init(allocator: std.mem.Allocator) SessionIdentityIndex {
        return .{
            .allocator = allocator,
            .path_to_session = std.StringHashMap(ids.SessionId).init(allocator),
            .session_to_path = std.AutoHashMap(ids.SessionId, []const u8).init(allocator),
            .attachment_to_session = std.AutoHashMap(usize, ids.SessionId).init(allocator),
        };
    }

    pub fn deinit(self: *SessionIdentityIndex) void {
        var session_path_it = self.session_to_path.iterator();
        while (session_path_it.next()) |entry| {
            self.allocator.free(entry.value_ptr.*);
        }
        self.path_to_session.deinit();
        self.session_to_path.deinit();
        self.attachment_to_session.deinit();
    }

    pub fn resolvePath(
        self: *SessionIdentityIndex,
        generator: *ids.Generator,
        path: []const u8,
    ) !ids.SessionId {
        if (self.path_to_session.get(path)) |session_id| {
            return session_id;
        }

        const session_id = generator.next(.session);
        try self.bindSession(session_id, null, path);
        return session_id;
    }

    pub fn sessionForAttachment(
        self: *const SessionIdentityIndex,
        attachment_key: usize,
    ) ?ids.SessionId {
        return self.attachment_to_session.get(attachment_key);
    }

    pub fn bindSession(
        self: *SessionIdentityIndex,
        session_id: ids.SessionId,
        attachment_key: ?usize,
        path: []const u8,
    ) !void {
        try self.bindPath(session_id, path);
        if (attachment_key) |key| {
            try self.attachment_to_session.put(key, session_id);
        }
    }

    pub fn pathForSession(
        self: *const SessionIdentityIndex,
        session_id: ids.SessionId,
    ) ?[]const u8 {
        return self.session_to_path.get(session_id);
    }

    pub fn retireSession(self: *SessionIdentityIndex, session_id: ids.SessionId) void {
        self.removeSessionPath(session_id);

        var stale_keys: std.ArrayList(usize) = .empty;
        defer stale_keys.deinit(self.allocator);

        var it = self.attachment_to_session.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.* == session_id) {
                stale_keys.append(self.allocator, entry.key_ptr.*) catch continue;
            }
        }

        for (stale_keys.items) |key| {
            _ = self.attachment_to_session.remove(key);
        }
    }

    pub fn pruneAttachments(
        self: *SessionIdentityIndex,
        live_attachment_keys: []const usize,
    ) !void {
        var stale_keys: std.ArrayList(usize) = .empty;
        defer stale_keys.deinit(self.allocator);

        var it = self.attachment_to_session.iterator();
        while (it.next()) |entry| {
            if (!containsUsize(live_attachment_keys, entry.key_ptr.*)) {
                try stale_keys.append(self.allocator, entry.key_ptr.*);
            }
        }

        for (stale_keys.items) |key| {
            _ = self.attachment_to_session.remove(key);
        }
    }

    fn bindPath(
        self: *SessionIdentityIndex,
        session_id: ids.SessionId,
        path: []const u8,
    ) !void {
        if (self.session_to_path.get(session_id)) |current_path| {
            if (std.mem.eql(u8, current_path, path)) return;
            self.removeSessionPath(session_id);
        }

        if (self.path_to_session.get(path)) |existing_session_id| {
            if (existing_session_id == session_id) {
                if (self.session_to_path.get(session_id) == null) {
                    const existing_path = self.path_to_session.getKey(path).?;
                    try self.session_to_path.put(session_id, existing_path);
                }
                return;
            }

            self.removeSessionPath(existing_session_id);
        }

        const owned_path = try self.allocator.dupe(u8, path);
        _ = try self.path_to_session.fetchPut(owned_path, session_id);
        try self.session_to_path.put(session_id, owned_path);
    }

    fn removeSessionPath(self: *SessionIdentityIndex, session_id: ids.SessionId) void {
        const removed = self.session_to_path.fetchRemove(session_id) orelse return;
        const path = removed.value;
        _ = self.path_to_session.fetchRemove(path);
        self.allocator.free(path);
    }
};

pub const SessionRecordStore = struct {
    allocator: std.mem.Allocator,
    records: std.AutoHashMap(ids.SessionId, SessionRecord),

    pub const SessionRecord = struct {
        workspace_id: ids.WorkspaceId,
        window_id: ids.WindowId,
        split_id: ids.SplitId,
        tab_id: ids.TabId,
        ordinal: usize = 0,
        title: []const u8,
        cwd: []const u8,
        focus_state: model.FocusState = .background,
        activity_state: model.ActivityState = .idle,
        is_attached: bool = false,
        attachment_key: ?usize = null,
    };

    pub const Upsert = struct {
        workspace_id: ids.WorkspaceId,
        window_id: ids.WindowId,
        split_id: ids.SplitId,
        tab_id: ids.TabId,
        ordinal: usize = 0,
        title: []const u8,
        cwd: []const u8,
        focus_state: model.FocusState = .background,
        activity_state: model.ActivityState = .idle,
        is_attached: bool = false,
        attachment_key: ?usize = null,
    };

    pub fn init(allocator: std.mem.Allocator) SessionRecordStore {
        return .{
            .allocator = allocator,
            .records = std.AutoHashMap(ids.SessionId, SessionRecord).init(allocator),
        };
    }

    pub fn deinit(self: *SessionRecordStore) void {
        var it = self.records.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.value_ptr.title);
            self.allocator.free(entry.value_ptr.cwd);
        }
        self.records.deinit();
    }

    pub fn upsert(
        self: *SessionRecordStore,
        session_id: ids.SessionId,
        value: Upsert,
    ) !void {
        const gop = try self.records.getOrPut(session_id);
        if (!gop.found_existing) {
            gop.value_ptr.* = .{
                .workspace_id = value.workspace_id,
                .window_id = value.window_id,
                .split_id = value.split_id,
                .tab_id = value.tab_id,
                .ordinal = value.ordinal,
                .title = try self.allocator.dupe(u8, value.title),
                .cwd = try self.allocator.dupe(u8, value.cwd),
                .focus_state = value.focus_state,
                .activity_state = value.activity_state,
                .is_attached = value.is_attached,
                .attachment_key = value.attachment_key,
            };
            return;
        }

        self.allocator.free(gop.value_ptr.title);
        self.allocator.free(gop.value_ptr.cwd);
        gop.value_ptr.* = .{
            .workspace_id = value.workspace_id,
            .window_id = value.window_id,
            .split_id = value.split_id,
            .tab_id = value.tab_id,
            .ordinal = value.ordinal,
            .title = try self.allocator.dupe(u8, value.title),
            .cwd = try self.allocator.dupe(u8, value.cwd),
            .focus_state = value.focus_state,
            .activity_state = value.activity_state,
            .is_attached = value.is_attached,
            .attachment_key = value.attachment_key,
        };
    }

    pub fn get(
        self: *const SessionRecordStore,
        session_id: ids.SessionId,
    ) ?SessionRecord {
        return self.records.get(session_id);
    }

    pub fn iterator(self: *const SessionRecordStore) @TypeOf(self.records.iterator()) {
        return self.records.iterator();
    }

    pub fn focusSession(self: *SessionRecordStore, session_id: ids.SessionId) void {
        var it = self.records.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.focus_state = if (entry.key_ptr.* == session_id)
                .focused
            else if (entry.value_ptr.focus_state == .focused)
                .background
            else
                entry.value_ptr.focus_state;
        }
    }

    pub fn markDetached(self: *SessionRecordStore, session_id: ids.SessionId) void {
        if (self.records.getPtr(session_id)) |record| {
            record.is_attached = false;
            record.attachment_key = null;
            if (record.focus_state == .focused or record.focus_state == .last_focused) {
                record.focus_state = .detached;
            }
        }
    }

    pub fn markExited(self: *SessionRecordStore, session_id: ids.SessionId) void {
        if (self.records.getPtr(session_id)) |record| {
            record.activity_state = .exited;
        }
    }

    pub fn retire(self: *SessionRecordStore, session_id: ids.SessionId) void {
        const removed = self.records.fetchRemove(session_id) orelse return;
        self.allocator.free(removed.value.title);
        self.allocator.free(removed.value.cwd);
    }
};

pub const Registry = struct {
    allocator: std.mem.Allocator,
    ids: ids.Generator = .{},
    workspaces: std.ArrayListUnmanaged(WorkspaceRuntime) = .empty,

    pub fn init(allocator: std.mem.Allocator) Registry {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Registry) void {
        for (self.workspaces.items) |*entry| entry.deinit(self.allocator);
        self.workspaces.deinit(self.allocator);
    }

    pub fn createWorkspace(
        self: *Registry,
        name: []const u8,
        slug: []const u8,
        created_at: []const u8,
    ) !*WorkspaceRuntime {
        const workspace_id = self.ids.next(.workspace);
        const created_at_owned = try self.allocator.dupe(u8, created_at);
        const updated_at_owned = try self.allocator.dupe(u8, created_at);
        try self.workspaces.append(self.allocator, .{
            .workspace = .{
                .workspace_id = workspace_id,
                .name = try self.allocator.dupe(u8, name),
                .slug = try self.allocator.dupe(u8, slug),
                .origin = .runtime,
                .created_at = created_at_owned,
                .updated_at = updated_at_owned,
            },
            .runtime_arena = std.heap.ArenaAllocator.init(self.allocator),
        });
        return &self.workspaces.items[self.workspaces.items.len - 1];
    }

    pub fn updateSelection(self: *Registry, workspace_id: ids.WorkspaceId, selection: WorkspaceSelection) !void {
        try selection.validate();
        const entry = self.findWorkspace(workspace_id) orelse return error.WorkspaceNotFound;
        try validateSelectionRoute(entry, selection);

        if (selection.selected_session_id) |selected_session_id| {
            for (entry.sessions.items) |*session| {
                if (session.session_id == selected_session_id) {
                    session.focus_state = .focused;
                } else if (session.focus_state == .focused) {
                    session.focus_state = .background;
                }
            }
        }

        entry.workspace.selected_window_id = selection.selected_window_id;
        entry.workspace.selected_split_id = selection.selected_split_id;
        entry.workspace.selected_tab_id = selection.selected_tab_id;
        entry.workspace.selected_session_id = selection.selected_session_id;
        try entry.workspace.validateSelection();
    }

    pub fn findWorkspace(self: *Registry, workspace_id: ids.WorkspaceId) ?*WorkspaceRuntime {
        for (self.workspaces.items) |*entry| {
            if (entry.workspace.workspace_id == workspace_id) return entry;
        }
        return null;
    }

    pub fn removeWorkspace(self: *Registry, workspace_id: ids.WorkspaceId) bool {
        for (self.workspaces.items, 0..) |*entry, index| {
            if (entry.workspace.workspace_id != workspace_id) continue;
            entry.deinit(self.allocator);
            _ = self.workspaces.swapRemove(index);
            return true;
        }

        return false;
    }
};

fn validateSelectionRoute(entry: *const WorkspaceRuntime, selection: WorkspaceSelection) !void {
    if (selection.selected_window_id) |selected_window_id| {
        _ = findWindow(entry, selected_window_id) orelse return error.SelectedWindowNotFound;
    }
    const selected_split = if (selection.selected_split_id) |selected_split_id|
        findSplit(entry, selected_split_id) orelse return error.SelectedSplitNotFound
    else
        null;
    const selected_tab = if (selection.selected_tab_id) |selected_tab_id|
        findTab(entry, selected_tab_id) orelse return error.SelectedTabNotFound
    else
        null;
    const selected_session = if (selection.selected_session_id) |selected_session_id|
        findSession(entry, selected_session_id) orelse return error.SelectedSessionNotFound
    else
        null;

    if (selected_split != null and selected_tab != null and selected_tab.?.split_id != selected_split.?.split_id) {
        return error.SelectedTabOutsideSplit;
    }
    if (selected_session != null and selected_tab != null and selected_session.?.tab_id != selected_tab.?.tab_id) {
        return error.SelectedSessionOutsideTab;
    }
    if (selected_session != null and selected_split != null and selected_session.?.split_id != selected_split.?.split_id) {
        return error.SelectedSessionOutsideSplit;
    }
}

fn findWindow(entry: *const WorkspaceRuntime, window_id: ids.WindowId) ?*const model.WindowRuntime {
    for (entry.windows.items) |*window| {
        if (window.window_id == window_id) return window;
    }
    return null;
}

fn findSplit(entry: *const WorkspaceRuntime, split_id: ids.SplitId) ?*const model.SplitRuntime {
    for (entry.splits.items) |*split| {
        if (split.split_id == split_id) return split;
    }
    return null;
}

fn findTab(entry: *const WorkspaceRuntime, tab_id: ids.TabId) ?*const model.TabRuntime {
    for (entry.tabs.items) |*tab| {
        if (tab.tab_id == tab_id) return tab;
    }
    return null;
}

fn findSession(entry: *const WorkspaceRuntime, session_id: ids.SessionId) ?*const model.Session {
    for (entry.sessions.items) |*session| {
        if (session.session_id == session_id) return session;
    }
    return null;
}

fn findLayoutNode(entry: *const WorkspaceRuntime, layout_node_id: []const u8) ?*const model.LayoutNode {
    for (entry.layout.items) |*node| {
        if (std.mem.eql(u8, node.layout_node_id, layout_node_id)) return node;
    }
    return null;
}

fn hasSurfaceAttachment(entry: *const WorkspaceRuntime, session_id: ids.SessionId) bool {
    for (entry.surfaces.items) |surface| {
        if (surface.session_id == session_id) return true;
    }
    return false;
}

fn visitSidebarLayoutChildren(
    runtime: *const WorkspaceRuntime,
    layout_node_id: []const u8,
    depth: usize,
    session_index: *usize,
    visitor: anytype,
) void {
    const node = findLayoutNode(runtime, layout_node_id) orelse return;
    switch (node.node_type) {
        .split_root, .tab => {
            for (node.child_ids) |child_id| {
                visitSidebarLayoutChildren(runtime, child_id, depth, session_index, visitor);
            }
        },
        .split => {
            visitor.visitLayoutSplit(node.split_direction, depth);
            for (node.child_ids) |child_id| {
                visitSidebarLayoutChildren(runtime, child_id, depth + 1, session_index, visitor);
            }
        },
        .session_leaf => {
            const session_id = node.session_id orelse return;
            const session = findSession(runtime, session_id) orelse return;
            session_index.* += 1;
            visitor.visitSession(
                session,
                session_index.*,
                runtime.workspace.selected_session_id != null and runtime.workspace.selected_session_id.? == session.session_id,
                hasSurfaceAttachment(runtime, session.session_id),
                depth,
            );
        },
    }
}

fn containsUsize(items: []const usize, needle: usize) bool {
    for (items) |item| {
        if (item == needle) return true;
    }
    return false;
}

test "workspace registry enforces selection hierarchy" {
    const testing = std.testing;

    var registry = Registry.init(testing.allocator);
    defer registry.deinit();

    const entry = try registry.createWorkspace("dev", "dev", "2026-03-22T00:00:00Z");
    entry.workspace.split_ids = &.{ids.SplitId.init(2)};
    entry.workspace.tab_ids = &.{ids.TabId.init(3)};
    entry.workspace.session_ids = &.{ids.SessionId.init(4)};
    try entry.windows.append(testing.allocator, .{
        .window_id = ids.WindowId.init(1),
        .workspace_id = entry.workspace.workspace_id,
        .is_active = true,
        .is_quick_terminal = false,
        .split_ids = &.{ids.SplitId.init(2)},
    });
    try entry.splits.append(testing.allocator, .{
        .split_id = ids.SplitId.init(2),
        .workspace_id = entry.workspace.workspace_id,
        .window_id = ids.WindowId.init(1),
        .title = "Workspace Split",
        .ordinal = 0,
        .tab_ids = &.{ids.TabId.init(3)},
        .layout_root_id = "split-root",
    });
    try entry.tabs.append(testing.allocator, .{
        .tab_id = ids.TabId.init(3),
        .split_id = ids.SplitId.init(2),
        .workspace_id = entry.workspace.workspace_id,
        .window_id = ids.WindowId.init(1),
        .title = "shell",
        .layout_root_id = "tab-root",
        .ordinal = 0,
    });
    try entry.layout.append(testing.allocator, .{
        .layout_node_id = "split-root",
        .workspace_id = entry.workspace.workspace_id,
        .split_id = ids.SplitId.init(2),
        .node_type = .split_root,
        .child_ids = &.{"tab-root"},
    });
    try entry.layout.append(testing.allocator, .{
        .layout_node_id = "tab-root",
        .workspace_id = entry.workspace.workspace_id,
        .split_id = ids.SplitId.init(2),
        .tab_id = ids.TabId.init(3),
        .node_type = .tab,
        .child_ids = &.{"layout-leaf"},
    });
    try entry.sessions.append(testing.allocator, .{
        .session_id = ids.SessionId.init(4),
        .workspace_id = entry.workspace.workspace_id,
        .window_id = ids.WindowId.init(1),
        .tab_id = ids.TabId.init(3),
        .split_id = ids.SplitId.init(2),
        .layout_node_id = "layout-leaf",
        .title = "shell",
        .cwd = "/tmp",
        .command = .{ .shell = "zsh" },
        .focus_state = .background,
    });

    try registry.updateSelection(entry.workspace.workspace_id, .{
        .selected_window_id = ids.WindowId.init(1),
        .selected_split_id = ids.SplitId.init(2),
        .selected_tab_id = ids.TabId.init(3),
        .selected_session_id = ids.SessionId.init(4),
    });

    try testing.expectEqual(ids.WindowId.init(1), entry.workspace.selected_window_id.?);
    try testing.expectError(error.SelectedTabRequiresSplit, registry.updateSelection(
        entry.workspace.workspace_id,
        .{ .selected_window_id = ids.WindowId.init(1), .selected_tab_id = ids.TabId.init(1) },
    ));
}

test "session identity index preserves session ids across attachment replacement and moves" {
    const testing = std.testing;

    var index = SessionIdentityIndex.init(testing.allocator);
    defer index.deinit();

    var generator = ids.Generator{};

    const first = try index.resolvePath(&generator, "tab-1:root/L");
    try index.bindSession(first, 1001, "tab-1:root/L");
    const replacement = try index.resolvePath(&generator, "tab-1:root/L");
    try testing.expectEqual(first, replacement);

    const moved = index.sessionForAttachment(1001).?;
    try index.bindSession(moved, 1001, "tab-1:root/R");
    try testing.expectEqual(first, moved);

    const new_at_old_path = try index.resolvePath(&generator, "tab-1:root/L");
    try index.bindSession(new_at_old_path, 2002, "tab-1:root/L");
    try testing.expect(new_at_old_path != first);

    try index.pruneAttachments(&.{2002});

    const replacement_after_prune = try index.resolvePath(&generator, "tab-1:root/R");
    try testing.expectEqual(first, replacement_after_prune);
}

test "session identity index retires closed sessions before recreate" {
    const testing = std.testing;

    var index = SessionIdentityIndex.init(testing.allocator);
    defer index.deinit();

    var generator = ids.Generator{};

    const first = try index.resolvePath(&generator, "tab-1:root/L");
    try index.bindSession(first, 1001, "tab-1:root/L");
    index.retireSession(first);

    const recreated = try index.resolvePath(&generator, "tab-1:root/L");
    try testing.expect(recreated != first);
}

test "session record store keeps unattached records until retirement" {
    const testing = std.testing;

    var store = SessionRecordStore.init(testing.allocator);
    defer store.deinit();

    const session_id = ids.SessionId.init(7);
    try store.upsert(session_id, .{
        .workspace_id = ids.WorkspaceId.init(1),
        .window_id = ids.WindowId.init(2),
        .split_id = ids.SplitId.init(3),
        .tab_id = ids.TabId.init(4),
        .title = "shell",
        .cwd = "/tmp",
        .focus_state = .focused,
        .activity_state = .idle,
        .is_attached = true,
        .attachment_key = 1001,
    });
    store.markExited(session_id);
    store.markDetached(session_id);

    const detached = store.get(session_id).?;
    try testing.expect(!detached.is_attached);
    try testing.expect(detached.attachment_key == null);
    try testing.expectEqual(model.FocusState.detached, detached.focus_state);
    try testing.expectEqual(model.ActivityState.exited, detached.activity_state);

    store.retire(session_id);
    try testing.expect(store.get(session_id) == null);
}
