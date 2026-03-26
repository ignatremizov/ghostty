const std = @import("std");
const ids = @import("workspace_ids.zig");
const model = @import("workspace_model.zig");
const registry = @import("workspace_registry.zig");

pub const current_version: u32 = 1;

pub fn formatUtcTimestampAlloc(alloc: std.mem.Allocator, unix_seconds: i64) ![]u8 {
    if (unix_seconds < 0) return error.UnsupportedTimestamp;

    const epoch_seconds = std.time.epoch.EpochSeconds{
        .secs = @as(u64, @intCast(unix_seconds)),
    };
    const epoch_day = epoch_seconds.getEpochDay();
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_seconds = epoch_seconds.getDaySeconds();

    return std.fmt.allocPrint(alloc, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
        day_seconds.getHoursIntoDay(),
        day_seconds.getMinutesIntoHour(),
        day_seconds.getSecondsIntoMinute(),
    });
}

pub fn currentUtcTimestampAlloc(alloc: std.mem.Allocator) ![]u8 {
    return formatUtcTimestampAlloc(alloc, std.time.timestamp());
}

pub const WorkspaceSelection = struct {
    workspace_id: ids.WorkspaceId,
    workspace_key: ?[]const u8 = null,
    name: []const u8,
    layout_root_node_id: ?[]const u8 = null,
    selected_window_id: ?ids.WindowId = null,
    selected_split_id: ?ids.SplitId = null,
    selected_tab_id: ?ids.TabId = null,
    selected_session_id: ?ids.SessionId = null,

    pub fn validate(self: WorkspaceSelection) !void {
        if (self.selected_split_id == null and self.selected_tab_id == null and self.selected_session_id == null) {
            return error.SelectionRequired;
        }
        if (self.layout_root_node_id) |layout_root_node_id| {
            if (layout_root_node_id.len == 0) return error.WorkspaceLayoutRootRequired;
        }
    }
};

pub const SplitRecord = struct {
    split_id: ids.SplitId,
    window_id: ?ids.WindowId = null,
    ordinal: usize,
    root_layout_node_id: []const u8,

    pub fn validate(self: SplitRecord) !void {
        if (self.root_layout_node_id.len == 0) return error.SplitRootLayoutNodeRequired;
    }

    pub fn deinit(self: SplitRecord, alloc: std.mem.Allocator) void {
        alloc.free(self.root_layout_node_id);
    }
};

pub const TabRecord = struct {
    tab_id: ids.TabId,
    ordinal: usize,
    title_override: ?[]const u8 = null,

    pub fn deinit(self: TabRecord, alloc: std.mem.Allocator) void {
        if (self.title_override) |title_override| alloc.free(title_override);
    }
};

pub const LayoutNodeRecord = struct {
    layout_node_id: []const u8,
    tab_id: ?ids.TabId = null,
    node_type: model.SnapshotNodeType,
    split_direction: ?model.SplitDirection = null,
    ratio: ?f64 = null,
    child_ids: ?[]const []const u8 = null,
    session_id: ?ids.SessionId = null,
    is_zoomed: bool = false,
    is_selected: bool = false,

    pub fn validate(self: LayoutNodeRecord) !void {
        switch (self.node_type) {
            .split_root => if (self.child_ids == null) return error.SplitRootRequiresChildren,
            .tab_root => if (self.child_ids == null) return error.TabRootRequiresChildren,
            .session_leaf => if (self.session_id == null) return error.SessionLeafRequiresSessionId,
            .split => {
                if (self.child_ids == null or self.split_direction == null) {
                    return error.SplitRequiresChildrenAndDirection;
                }
            },
        }
    }

    pub fn deinit(self: LayoutNodeRecord, alloc: std.mem.Allocator) void {
        alloc.free(self.layout_node_id);
        if (self.child_ids) |child_ids| {
            for (child_ids) |child_id| alloc.free(child_id);
            alloc.free(child_ids);
        }
    }
};

pub const SessionRecord = struct {
    session_id: ids.SessionId,
    tab_id: ids.TabId,
    cwd: []const u8,
    command: model.Command,
    env_overrides: []const model.EnvOverride = &.{},
    title_override: ?[]const u8 = null,
    focus_preferred: bool = false,

    pub fn deinit(self: SessionRecord, alloc: std.mem.Allocator) void {
        alloc.free(self.cwd);
        switch (self.command) {
            .argv => |argv| {
                for (argv) |arg| alloc.free(arg);
                alloc.free(argv);
            },
            .shell => |shell| alloc.free(shell),
        }
        for (self.env_overrides) |env_override| {
            alloc.free(env_override.key);
            alloc.free(env_override.value);
        }
        alloc.free(self.env_overrides);
        if (self.title_override) |title_override| alloc.free(title_override);
    }
};

pub const Snapshot = struct {
    version: u32 = current_version,
    snapshot_id: ids.SnapshotId,
    saved_at: []const u8,
    workspace: WorkspaceSelection,
    splits: []const SplitRecord = &.{},
    tabs: []const TabRecord,
    layout: []const LayoutNodeRecord,
    sessions: []const SessionRecord,
    restore_results: ?model.RestoreResults = null,

    pub fn validate(self: Snapshot) !void {
        if (self.version < 1) return error.InvalidSnapshotVersion;
        try self.workspace.validate();

        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        var split_map = std.AutoHashMap(ids.SplitId, usize).init(alloc);
        var tab_map = std.AutoHashMap(ids.TabId, usize).init(alloc);
        var session_map = std.AutoHashMap(ids.SessionId, usize).init(alloc);
        var split_for_tab = std.AutoHashMap(ids.TabId, ids.SplitId).init(alloc);
        var layout_map = std.StringHashMap(usize).init(alloc);
        var split_root_map = std.StringHashMap(ids.SplitId).init(alloc);

        for (self.splits, 0..) |split, index| {
            try split.validate();
            const split_gop = try split_map.getOrPut(split.split_id);
            if (split_gop.found_existing) return error.DuplicateSplitId;
            split_gop.value_ptr.* = index;

            const split_root_gop = try split_root_map.getOrPut(split.root_layout_node_id);
            if (split_root_gop.found_existing) return error.DuplicateSplitRootLayoutNodeId;
            split_root_gop.value_ptr.* = split.split_id;
        }

        for (self.tabs, 0..) |tab, index| {
            const gop = try tab_map.getOrPut(tab.tab_id);
            if (gop.found_existing) return error.DuplicateTabId;
            gop.value_ptr.* = index;
        }

        for (self.sessions, 0..) |session, index| {
            const gop = try session_map.getOrPut(session.session_id);
            if (gop.found_existing) return error.DuplicateSessionId;
            gop.value_ptr.* = index;
        }

        for (self.layout, 0..) |entry, index| {
            try entry.validate();
            const gop = try layout_map.getOrPut(entry.layout_node_id);
            if (gop.found_existing) return error.DuplicateLayoutNodeId;
            gop.value_ptr.* = index;
        }

        for (self.splits) |split| {
            const root_index = layout_map.get(split.root_layout_node_id) orelse return error.SplitRootMissing;
            const root = self.layout[root_index];
            if (root.node_type != .split_root) return error.SplitRootNodeTypeMismatch;
            const split_tab_ids = try resolveSplitTabIdsAlloc(alloc, split, self.layout);
            for (split_tab_ids) |tab_id| {
                _ = tab_map.get(tab_id) orelse return error.SplitReferencesUnknownTab;
                const split_tab_gop = try split_for_tab.getOrPut(tab_id);
                if (split_tab_gop.found_existing) return error.TabAssignedToMultipleSplits;
                split_tab_gop.value_ptr.* = split.split_id;
            }
            alloc.free(split_tab_ids);
        }

        for (self.tabs) |tab| {
            if (!split_for_tab.contains(tab.tab_id)) return error.TabMissingSplitOwnership;

            const root_layout_node_id = try resolveTabRootLayoutNodeId(tab.tab_id, self.layout);
            const root_index = layout_map.get(root_layout_node_id) orelse return error.TabRootMissing;
            const root = self.layout[root_index];
            if (root.node_type != .tab_root) return error.TabRootNodeTypeMismatch;
            if (root.tab_id != tab.tab_id) return error.TabRootOutsideTab;
        }

        for (self.sessions) |session| {
            if (!tab_map.contains(session.tab_id)) return error.SessionOutsideTab;
            if (!split_for_tab.contains(session.tab_id)) return error.SessionMissingSplitOwnership;
        }

        for (self.layout) |entry| {
            switch (entry.node_type) {
                .split_root => {
                    const split_id = split_root_map.get(entry.layout_node_id) orelse return error.OrphanSplitRootLayoutNode;
                    _ = self.splits[split_map.get(split_id).?];
                    const child_ids = entry.child_ids orelse return error.SplitRootRequiresChildren;
                    for (child_ids) |child_id| {
                        const child = self.layout[layout_map.get(child_id) orelse return error.LayoutChildMissing];
                        if (child.node_type != .tab_root) return error.SplitRootChildMustBeTabRoot;
                    }
                },
                .tab_root, .split => {
                    if (entry.tab_id == null) {
                        if (entry.node_type != .split) return error.WorkspaceLayoutNodeTypeMismatch;
                        const child_ids = entry.child_ids orelse return error.LayoutNodeMissingChildren;
                        for (child_ids) |child_id| {
                            const child = self.layout[layout_map.get(child_id) orelse return error.LayoutChildMissing];
                            if (child.node_type != .split_root and !(child.node_type == .split and child.tab_id == null)) {
                                return error.WorkspaceLayoutChildInvalid;
                            }
                        }
                        continue;
                    }

                    if (!split_for_tab.contains(entry.tab_id.?)) return error.LayoutNodeOutsideSplit;
                    const child_ids = entry.child_ids orelse return error.LayoutNodeMissingChildren;
                    for (child_ids) |child_id| {
                        const child = self.layout[layout_map.get(child_id) orelse return error.LayoutChildMissing];
                        if (child.node_type == .split_root) return error.LayoutChildCrossesSplitRootBoundary;
                        if (child.tab_id != entry.tab_id) return error.LayoutChildOutsideTab;
                    }
                },
                .session_leaf => {
                    const session_id = entry.session_id orelse return error.SessionLeafRequiresSessionId;
                    const session = self.sessions[session_map.get(session_id) orelse return error.LayoutNodeReferencesUnknownSession];
                    if (session.tab_id != entry.tab_id) return error.SessionLayoutTabMismatch;
                    if (entry.tab_id == null or !split_for_tab.contains(entry.tab_id.?)) {
                        return error.LayoutNodeOutsideSplit;
                    }
                },
            }
        }

        if (self.workspace.layout_root_node_id) |layout_root_node_id| {
            const root_index = layout_map.get(layout_root_node_id) orelse return error.WorkspaceLayoutRootMissing;
            const root = self.layout[root_index];
            switch (root.node_type) {
                .split_root => {},
                .split => if (root.tab_id != null) return error.WorkspaceLayoutRootMustBeWorkspaceSplit,
                else => return error.WorkspaceLayoutRootInvalid,
            }

            var reachable_split_roots = std.StringHashMap(void).init(alloc);
            defer reachable_split_roots.deinit();
            try collectReachableSplitRoots(
                self.layout,
                &layout_map,
                &reachable_split_roots,
                layout_root_node_id,
            );

            for (self.splits) |split| {
                if (!reachable_split_roots.contains(split.root_layout_node_id)) {
                    return error.SplitRootNotReachableFromWorkspaceLayout;
                }
            }
        }

        if (self.workspace.selected_split_id) |selected_split_id| {
            if (!split_map.contains(selected_split_id)) return error.SelectedSplitNotFound;
            if (self.workspace.selected_window_id) |selected_window_id| {
                const split = self.splits[split_map.get(selected_split_id).?];
                if (split.window_id != null and split.window_id.? != selected_window_id) {
                    return error.SelectedSplitOutsideWindow;
                }
            }
        }
        if (self.workspace.selected_tab_id) |selected_tab_id| {
            if (!tab_map.contains(selected_tab_id)) return error.SelectedTabNotFound;
            if (self.workspace.selected_split_id) |selected_split_id| {
                const tab_split_id = split_for_tab.get(selected_tab_id) orelse return error.SelectedTabMissingSplit;
                if (tab_split_id != selected_split_id) return error.SelectedTabOutsideSplit;
            }
        }
        if (self.workspace.selected_session_id) |selected_session_id| {
            const session = self.sessions[session_map.get(selected_session_id) orelse return error.SelectedSessionNotFound];
            if (self.workspace.selected_tab_id) |selected_tab_id| {
                if (session.tab_id != selected_tab_id) return error.SelectedSessionOutsideTab;
            }
            if (self.workspace.selected_split_id) |selected_split_id| {
                const session_split_id = split_for_tab.get(session.tab_id) orelse return error.SelectedSessionMissingSplit;
                if (session_split_id != selected_split_id) return error.SelectedSessionOutsideSplit;
            }
        }
    }

    pub fn encodeAlloc(self: Snapshot, alloc: std.mem.Allocator) ![]u8 {
        try self.validate();

        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();
        try std.json.Stringify.value(self, .{ .whitespace = .indent_2 }, &out.writer);
        return out.toOwnedSlice();
    }

    pub fn decodeAlloc(alloc: std.mem.Allocator, data: []const u8) !Snapshot {
        const parsed = try std.json.parseFromSliceLeaky(Snapshot, alloc, data, .{
            .allocate = .alloc_always,
        });
        try parsed.validate();
        return parsed;
    }

    pub fn deinit(self: Snapshot, alloc: std.mem.Allocator) void {
        alloc.free(self.saved_at);
        if (self.workspace.workspace_key) |workspace_key| alloc.free(workspace_key);
        if (self.workspace.layout_root_node_id) |layout_root_node_id| alloc.free(layout_root_node_id);
        alloc.free(self.workspace.name);

        for (self.splits) |split| split.deinit(alloc);
        if (self.splits.len > 0) alloc.free(self.splits);

        for (self.tabs) |tab| tab.deinit(alloc);
        alloc.free(self.tabs);

        for (self.layout) |entry| entry.deinit(alloc);
        alloc.free(self.layout);

        for (self.sessions) |session| session.deinit(alloc);
        alloc.free(self.sessions);

        if (self.restore_results) |restore_results| {
            alloc.free(restore_results.restored_session_ids);
            for (restore_results.failed_sessions) |failure| {
                alloc.free(failure.code);
                alloc.free(failure.message);
            }
            alloc.free(restore_results.failed_sessions);
            if (restore_results.selection_fallback) |selection_fallback| {
                alloc.free(selection_fallback.reason);
            }
        }
    }
};

pub fn fromRuntimeAlloc(
    alloc: std.mem.Allocator,
    snapshot_id: ids.SnapshotId,
    saved_at: []const u8,
    runtime: *const registry.WorkspaceRuntime,
) !Snapshot {
    var splits: std.ArrayList(SplitRecord) = .empty;
    errdefer {
        for (splits.items) |value| value.deinit(alloc);
        splits.deinit(alloc);
    }

    for (runtime.splits.items) |value| {
        try splits.append(alloc, .{
            .split_id = value.split_id,
            .window_id = value.window_id,
            .ordinal = value.ordinal,
            .root_layout_node_id = try alloc.dupe(u8, value.layout_root_id),
        });
    }

    var tabs: std.ArrayList(TabRecord) = .empty;
    errdefer {
        for (tabs.items) |value| value.deinit(alloc);
        tabs.deinit(alloc);
    }

    for (runtime.tabs.items) |value| {
        try tabs.append(alloc, .{
            .tab_id = value.tab_id,
            .ordinal = value.ordinal,
            .title_override = if (value.title_override) |title_override|
                try alloc.dupe(u8, title_override)
            else
                null,
        });
    }

    var layout: std.ArrayList(LayoutNodeRecord) = .empty;
    errdefer {
        for (layout.items) |value| value.deinit(alloc);
        layout.deinit(alloc);
    }

    for (runtime.layout.items) |value| {
        try layout.append(alloc, .{
            .layout_node_id = try alloc.dupe(u8, value.layout_node_id),
            .tab_id = value.tab_id,
            .node_type = model.SnapshotNodeType.fromRuntime(value.node_type) orelse unreachable,
            .split_direction = value.split_direction,
            .ratio = value.ratio,
            .child_ids = if (value.child_ids.len > 0)
                try cloneStringSliceAlloc(alloc, value.child_ids)
            else
                null,
            .session_id = value.session_id,
            .is_zoomed = value.is_zoomed,
            .is_selected = value.is_selected,
        });
    }

    var sessions: std.ArrayList(SessionRecord) = .empty;
    errdefer {
        for (sessions.items) |value| value.deinit(alloc);
        sessions.deinit(alloc);
    }

    for (runtime.sessions.items) |value| {
        try sessions.append(alloc, .{
            .session_id = value.session_id,
            .tab_id = value.tab_id,
            .cwd = try alloc.dupe(u8, value.cwd),
            .command = try cloneCommandAlloc(alloc, value.command),
            .env_overrides = try cloneEnvOverridesAlloc(alloc, value.env_overrides),
            .title_override = if (value.title_override) |title_override|
                try alloc.dupe(u8, title_override)
            else
                null,
            .focus_preferred = runtime.workspace.selected_session_id != null and
                runtime.workspace.selected_session_id.? == value.session_id,
        });
    }

    return .{
        .snapshot_id = snapshot_id,
        .saved_at = try alloc.dupe(u8, saved_at),
        .workspace = .{
            .workspace_id = runtime.workspace.workspace_id,
            .workspace_key = try alloc.dupe(u8, runtime.workspace.slug),
            .name = try alloc.dupe(u8, runtime.workspace.name),
            .layout_root_node_id = if (runtime.workspace.layout_root_id) |layout_root_node_id|
                try alloc.dupe(u8, layout_root_node_id)
            else
                null,
            .selected_window_id = runtime.workspace.selected_window_id,
            .selected_split_id = runtime.workspace.selected_split_id,
            .selected_tab_id = runtime.workspace.selected_tab_id,
            .selected_session_id = runtime.workspace.selected_session_id,
        },
        .splits = try splits.toOwnedSlice(alloc),
        .tabs = try tabs.toOwnedSlice(alloc),
        .layout = try layout.toOwnedSlice(alloc),
        .sessions = try sessions.toOwnedSlice(alloc),
        .restore_results = null,
    };
}

pub fn resolveSplitTabIdsAlloc(
    alloc: std.mem.Allocator,
    split: SplitRecord,
    layout: []const LayoutNodeRecord,
) ![]ids.TabId {
    const root = findLayoutNode(layout, split.root_layout_node_id) orelse return error.SplitRootMissing;
    if (root.node_type != .split_root) return error.SplitRootNodeTypeMismatch;
    const child_ids = root.child_ids orelse return error.SplitRootRequiresChildren;
    if (child_ids.len == 0) return error.SplitRequiresTabs;

    const tab_ids = try alloc.alloc(ids.TabId, child_ids.len);
    errdefer alloc.free(tab_ids);

    for (child_ids, 0..) |child_id, index| {
        const child = findLayoutNode(layout, child_id) orelse return error.LayoutChildMissing;
        if (child.node_type != .tab_root) return error.SplitRootChildMustBeTabRoot;
        const tab_id = child.tab_id orelse return error.SplitRootChildOutsideSplit;
        tab_ids[index] = tab_id;
    }

    return tab_ids;
}

pub fn resolveTabRootLayoutNodeId(
    tab_id: ids.TabId,
    layout: []const LayoutNodeRecord,
) ![]const u8 {
    var derived_root_layout_node_id: ?[]const u8 = null;
    for (layout) |entry| {
        if (entry.node_type != .tab_root or entry.tab_id != tab_id) continue;
        if (derived_root_layout_node_id != null) return error.DuplicateTabRootLayoutNodeId;
        derived_root_layout_node_id = entry.layout_node_id;
    }

    return derived_root_layout_node_id orelse error.TabRootMissing;
}

fn cloneStringSliceAlloc(
    alloc: std.mem.Allocator,
    values: []const []const u8,
) ![]const []const u8 {
    var owned: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (owned.items) |value| alloc.free(value);
        owned.deinit(alloc);
    }

    for (values) |value| {
        try owned.append(alloc, try alloc.dupe(u8, value));
    }

    return owned.toOwnedSlice(alloc);
}

fn cloneCommandAlloc(
    alloc: std.mem.Allocator,
    command: model.Command,
) !model.Command {
    return switch (command) {
        .argv => |argv| .{ .argv = try cloneStringSliceAlloc(alloc, argv) },
        .shell => |shell| .{ .shell = try alloc.dupe(u8, shell) },
    };
}

fn cloneEnvOverridesAlloc(
    alloc: std.mem.Allocator,
    env_overrides: []const model.EnvOverride,
) ![]const model.EnvOverride {
    const owned = try alloc.alloc(model.EnvOverride, env_overrides.len);
    errdefer alloc.free(owned);

    var initialized: usize = 0;
    errdefer {
        for (owned[0..initialized]) |item| {
            alloc.free(item.key);
            alloc.free(item.value);
        }
    }

    for (env_overrides, 0..) |value, index| {
        owned[index] = .{
            .key = try alloc.dupe(u8, value.key),
            .value = try alloc.dupe(u8, value.value),
        };
        initialized += 1;
    }

    return owned;
}

fn collectReachableSplitRoots(
    layout: []const LayoutNodeRecord,
    layout_map: *const std.StringHashMap(usize),
    reachable_split_roots: *std.StringHashMap(void),
    layout_node_id: []const u8,
) !void {
    const entry = layout[layout_map.get(layout_node_id) orelse return error.LayoutChildMissing];
    switch (entry.node_type) {
        .split_root => {
            const gop = try reachable_split_roots.getOrPut(entry.layout_node_id);
            if (gop.found_existing) return;
        },
        .split => {
            if (entry.tab_id != null) return error.WorkspaceLayoutChildInvalid;
            const child_ids = entry.child_ids orelse return error.LayoutNodeMissingChildren;
            for (child_ids) |child_id| {
                try collectReachableSplitRoots(layout, layout_map, reachable_split_roots, child_id);
            }
        },
        else => return error.WorkspaceLayoutChildInvalid,
    }
}

fn findLayoutNode(
    layout: []const LayoutNodeRecord,
    layout_node_id: []const u8,
) ?LayoutNodeRecord {
    for (layout) |entry| {
        if (std.mem.eql(u8, entry.layout_node_id, layout_node_id)) return entry;
    }
    return null;
}

pub const CatalogEntry = struct {
    snapshot_id: ids.SnapshotId,
    workspace_id: ids.WorkspaceId,
    workspace_key: ?[]const u8 = null,
    workspace_name: []const u8,
    saved_at: []const u8,
    path: []const u8,

    pub fn cloneAlloc(self: CatalogEntry, alloc: std.mem.Allocator) !CatalogEntry {
        return .{
            .snapshot_id = self.snapshot_id,
            .workspace_id = self.workspace_id,
            .workspace_key = if (self.workspace_key) |workspace_key|
                try alloc.dupe(u8, workspace_key)
            else
                null,
            .workspace_name = try alloc.dupe(u8, self.workspace_name),
            .saved_at = try alloc.dupe(u8, self.saved_at),
            .path = try alloc.dupe(u8, self.path),
        };
    }

    pub fn deinit(self: CatalogEntry, alloc: std.mem.Allocator) void {
        if (self.workspace_key) |workspace_key| alloc.free(workspace_key);
        alloc.free(self.workspace_name);
        alloc.free(self.saved_at);
        alloc.free(self.path);
    }
};

pub fn catalogEntryAlloc(
    alloc: std.mem.Allocator,
    value: Snapshot,
    path: []const u8,
) !CatalogEntry {
    return .{
        .snapshot_id = value.snapshot_id,
        .workspace_id = value.workspace.workspace_id,
        .workspace_key = if (value.workspace.workspace_key) |workspace_key|
            try alloc.dupe(u8, workspace_key)
        else
            null,
        .workspace_name = try alloc.dupe(u8, value.workspace.name),
        .saved_at = try alloc.dupe(u8, value.saved_at),
        .path = try alloc.dupe(u8, path),
    };
}

pub const Catalog = struct {
    version: u32 = current_version,
    entries: []const CatalogEntry = &.{},

    pub fn encodeAlloc(self: Catalog, alloc: std.mem.Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();
        try std.json.Stringify.value(self, .{ .whitespace = .indent_2 }, &out.writer);
        return out.toOwnedSlice();
    }

    pub fn decodeAlloc(alloc: std.mem.Allocator, data: []const u8) !Catalog {
        const parsed = try std.json.parseFromSliceLeaky(Catalog, alloc, data, .{
            .allocate = .alloc_always,
        });
        if (parsed.version < 1) return error.InvalidSnapshotVersion;
        return parsed;
    }

    pub fn deinit(self: Catalog, alloc: std.mem.Allocator) void {
        for (self.entries) |entry| entry.deinit(alloc);
        if (self.entries.len > 0) alloc.free(self.entries);
    }
};

test {
    _ = @import("workspace_snapshot_test.zig");
}
