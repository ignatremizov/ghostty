const std = @import("std");
const global = @import("../../global.zig");
const ids = @import("workspace_ids.zig");
const model = @import("workspace_model.zig");
const registry = @import("workspace_registry.zig");

pub const current_version: u32 = 1;
pub const max_layout_depth: usize = 256;

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
    return formatUtcTimestampAlloc(
        alloc,
        std.Io.Timestamp.now(global.io(), .real).toSeconds(),
    );
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
        if (self.ratio) |ratio| {
            if (!std.math.isFinite(ratio) or ratio < 0 or ratio > 1) {
                return error.InvalidSplitRatio;
            }
        }
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
    scrollback_path: ?[]const u8 = null,
    focus_preferred: bool = false,

    pub fn validate(self: SessionRecord) !void {
        if (self.scrollback_path) |path| {
            if (path.len == 0) return error.SessionScrollbackPathRequired;
        }
    }

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
        if (self.scrollback_path) |scrollback_path| alloc.free(scrollback_path);
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
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        try self.validateWithAllocator(arena.allocator());
    }

    pub fn validateWithAllocator(self: Snapshot, alloc: std.mem.Allocator) !void {
        if (self.version != current_version) return error.InvalidSnapshotVersion;
        try self.workspace.validate();

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
            try session.validate();
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
        try validateLayoutAcyclic(alloc, self.layout, &layout_map);

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
                alloc,
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
        const parsed = try std.json.parseFromSlice(Snapshot, alloc, data, .{
            .allocate = .alloc_always,
        });
        defer parsed.deinit();
        try parsed.value.validate();
        return cloneSnapshotAlloc(alloc, parsed.value);
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

fn cloneSnapshotAlloc(
    alloc: std.mem.Allocator,
    value: Snapshot,
) !Snapshot {
    const saved_at = try alloc.dupe(u8, value.saved_at);
    errdefer alloc.free(saved_at);
    const workspace = try cloneWorkspaceSelectionAlloc(alloc, value.workspace);
    errdefer deinitWorkspaceSelection(workspace, alloc);
    const splits = try cloneSplitRecordsAlloc(alloc, value.splits);
    errdefer deinitSplitRecords(splits, alloc);
    const tabs = try cloneTabRecordsAlloc(alloc, value.tabs);
    errdefer deinitTabRecords(tabs, alloc);
    const layout = try cloneLayoutNodeRecordsAlloc(alloc, value.layout);
    errdefer deinitLayoutNodeRecords(layout, alloc);
    const sessions = try cloneSessionRecordsAlloc(alloc, value.sessions);
    errdefer deinitSessionRecords(sessions, alloc);
    const restore_results = if (value.restore_results) |results|
        try cloneRestoreResultsAlloc(alloc, results)
    else
        null;
    errdefer if (restore_results) |results| deinitRestoreResults(results, alloc);

    return .{
        .version = value.version,
        .snapshot_id = value.snapshot_id,
        .saved_at = saved_at,
        .workspace = workspace,
        .splits = splits,
        .tabs = tabs,
        .layout = layout,
        .sessions = sessions,
        .restore_results = restore_results,
    };
}

fn cloneWorkspaceSelectionAlloc(
    alloc: std.mem.Allocator,
    value: WorkspaceSelection,
) !WorkspaceSelection {
    const workspace_key = if (value.workspace_key) |key|
        try alloc.dupe(u8, key)
    else
        null;
    errdefer if (workspace_key) |key| alloc.free(key);
    const name = try alloc.dupe(u8, value.name);
    errdefer alloc.free(name);
    const layout_root_node_id = if (value.layout_root_node_id) |id|
        try alloc.dupe(u8, id)
    else
        null;
    errdefer if (layout_root_node_id) |id| alloc.free(id);

    return .{
        .workspace_id = value.workspace_id,
        .workspace_key = workspace_key,
        .name = name,
        .layout_root_node_id = layout_root_node_id,
        .selected_window_id = value.selected_window_id,
        .selected_split_id = value.selected_split_id,
        .selected_tab_id = value.selected_tab_id,
        .selected_session_id = value.selected_session_id,
    };
}

fn deinitWorkspaceSelection(
    value: WorkspaceSelection,
    alloc: std.mem.Allocator,
) void {
    if (value.workspace_key) |workspace_key| alloc.free(workspace_key);
    alloc.free(value.name);
    if (value.layout_root_node_id) |layout_root_node_id| {
        alloc.free(layout_root_node_id);
    }
}

fn cloneSplitRecordsAlloc(
    alloc: std.mem.Allocator,
    values: []const SplitRecord,
) ![]const SplitRecord {
    const owned = try alloc.alloc(SplitRecord, values.len);
    var initialized: usize = 0;
    errdefer {
        for (owned[0..initialized]) |value| value.deinit(alloc);
        alloc.free(owned);
    }
    for (values, 0..) |value, index| {
        owned[index] = .{
            .split_id = value.split_id,
            .window_id = value.window_id,
            .ordinal = value.ordinal,
            .root_layout_node_id = try alloc.dupe(u8, value.root_layout_node_id),
        };
        initialized += 1;
    }
    return owned;
}

fn deinitSplitRecords(values: []const SplitRecord, alloc: std.mem.Allocator) void {
    for (values) |value| value.deinit(alloc);
    alloc.free(values);
}

fn cloneTabRecordsAlloc(
    alloc: std.mem.Allocator,
    values: []const TabRecord,
) ![]const TabRecord {
    const owned = try alloc.alloc(TabRecord, values.len);
    var initialized: usize = 0;
    errdefer {
        for (owned[0..initialized]) |value| value.deinit(alloc);
        alloc.free(owned);
    }
    for (values, 0..) |value, index| {
        owned[index] = .{
            .tab_id = value.tab_id,
            .ordinal = value.ordinal,
            .title_override = if (value.title_override) |title|
                try alloc.dupe(u8, title)
            else
                null,
        };
        initialized += 1;
    }
    return owned;
}

fn deinitTabRecords(values: []const TabRecord, alloc: std.mem.Allocator) void {
    for (values) |value| value.deinit(alloc);
    alloc.free(values);
}

fn cloneLayoutNodeRecordsAlloc(
    alloc: std.mem.Allocator,
    values: []const LayoutNodeRecord,
) ![]const LayoutNodeRecord {
    const owned = try alloc.alloc(LayoutNodeRecord, values.len);
    var initialized: usize = 0;
    errdefer {
        for (owned[0..initialized]) |value| value.deinit(alloc);
        alloc.free(owned);
    }
    for (values, 0..) |value, index| {
        const layout_node_id = try alloc.dupe(u8, value.layout_node_id);
        errdefer alloc.free(layout_node_id);
        const child_ids = if (value.child_ids) |child_ids|
            try cloneStringSliceAlloc(alloc, child_ids)
        else
            null;
        errdefer if (child_ids) |ids_| {
            for (ids_) |id| alloc.free(id);
            alloc.free(ids_);
        };
        owned[index] = .{
            .layout_node_id = layout_node_id,
            .tab_id = value.tab_id,
            .node_type = value.node_type,
            .split_direction = value.split_direction,
            .ratio = value.ratio,
            .child_ids = child_ids,
            .session_id = value.session_id,
            .is_zoomed = value.is_zoomed,
            .is_selected = value.is_selected,
        };
        initialized += 1;
    }
    return owned;
}

fn deinitLayoutNodeRecords(
    values: []const LayoutNodeRecord,
    alloc: std.mem.Allocator,
) void {
    for (values) |value| value.deinit(alloc);
    alloc.free(values);
}

fn cloneSessionRecordsAlloc(
    alloc: std.mem.Allocator,
    values: []const SessionRecord,
) ![]const SessionRecord {
    const owned = try alloc.alloc(SessionRecord, values.len);
    var initialized: usize = 0;
    errdefer {
        for (owned[0..initialized]) |value| value.deinit(alloc);
        alloc.free(owned);
    }
    for (values, 0..) |value, index| {
        const cwd = try alloc.dupe(u8, value.cwd);
        errdefer alloc.free(cwd);
        const command = try cloneCommandAlloc(alloc, value.command);
        errdefer deinitCommand(command, alloc);
        const env_overrides = try cloneEnvOverridesAlloc(alloc, value.env_overrides);
        errdefer deinitEnvOverrides(env_overrides, alloc);
        const title_override = if (value.title_override) |title|
            try alloc.dupe(u8, title)
        else
            null;
        errdefer if (title_override) |title| alloc.free(title);
        const scrollback_path = if (value.scrollback_path) |path|
            try alloc.dupe(u8, path)
        else
            null;
        errdefer if (scrollback_path) |path| alloc.free(path);
        owned[index] = .{
            .session_id = value.session_id,
            .tab_id = value.tab_id,
            .cwd = cwd,
            .command = command,
            .env_overrides = env_overrides,
            .title_override = title_override,
            .scrollback_path = scrollback_path,
            .focus_preferred = value.focus_preferred,
        };
        initialized += 1;
    }
    return owned;
}

fn deinitSessionRecords(
    values: []const SessionRecord,
    alloc: std.mem.Allocator,
) void {
    for (values) |value| value.deinit(alloc);
    alloc.free(values);
}

fn cloneRestoreResultsAlloc(
    alloc: std.mem.Allocator,
    value: model.RestoreResults,
) !model.RestoreResults {
    const restored_session_ids = try alloc.dupe(
        ids.SessionId,
        value.restored_session_ids,
    );
    errdefer alloc.free(restored_session_ids);
    const failed_sessions = try alloc.alloc(
        model.RestoreFailure,
        value.failed_sessions.len,
    );
    var initialized: usize = 0;
    errdefer {
        for (failed_sessions[0..initialized]) |failure| {
            alloc.free(failure.code);
            alloc.free(failure.message);
        }
        alloc.free(failed_sessions);
    }
    for (value.failed_sessions, 0..) |failure, index| {
        const code = try alloc.dupe(u8, failure.code);
        errdefer alloc.free(code);
        const message = try alloc.dupe(u8, failure.message);
        errdefer alloc.free(message);
        failed_sessions[index] = .{
            .session_id = failure.session_id,
            .code = code,
            .message = message,
        };
        initialized += 1;
    }
    const selection_fallback = if (value.selection_fallback) |fallback|
        model.SelectionFallback{
            .window_id = fallback.window_id,
            .tab_id = fallback.tab_id,
            .session_id = fallback.session_id,
            .reason = try alloc.dupe(u8, fallback.reason),
        }
    else
        null;
    errdefer if (selection_fallback) |fallback| alloc.free(fallback.reason);

    return .{
        .restored_workspace_id = value.restored_workspace_id,
        .restored_session_ids = restored_session_ids,
        .failed_sessions = failed_sessions,
        .selection_fallback = selection_fallback,
    };
}

fn deinitRestoreResults(
    value: model.RestoreResults,
    alloc: std.mem.Allocator,
) void {
    alloc.free(value.restored_session_ids);
    for (value.failed_sessions) |failure| {
        alloc.free(failure.code);
        alloc.free(failure.message);
    }
    alloc.free(value.failed_sessions);
    if (value.selection_fallback) |fallback| alloc.free(fallback.reason);
}

fn deinitCommand(command: model.Command, alloc: std.mem.Allocator) void {
    switch (command) {
        .argv => |argv| {
            for (argv) |arg| alloc.free(arg);
            alloc.free(argv);
        },
        .shell => |shell| alloc.free(shell),
    }
}

fn deinitEnvOverrides(
    env_overrides: []const model.EnvOverride,
    alloc: std.mem.Allocator,
) void {
    for (env_overrides) |env_override| {
        alloc.free(env_override.key);
        alloc.free(env_override.value);
    }
    alloc.free(env_overrides);
}

pub fn setSessionScrollbackPathAlloc(
    value: *Snapshot,
    alloc: std.mem.Allocator,
    session_id: ids.SessionId,
    path: []const u8,
) !void {
    const sessions: []SessionRecord = @constCast(value.sessions);
    for (sessions) |*session| {
        if (session.session_id != session_id) continue;
        const owned_path = try alloc.dupe(u8, path);
        errdefer alloc.free(owned_path);
        if (session.scrollback_path) |old_path| alloc.free(old_path);
        session.scrollback_path = owned_path;
        return;
    }

    return error.SessionNotFound;
}

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
        var root_layout_node_id: ?[]u8 = try alloc.dupe(u8, value.layout_root_id);
        errdefer if (root_layout_node_id) |id| alloc.free(id);
        try splits.append(alloc, .{
            .split_id = value.split_id,
            .window_id = value.window_id,
            .ordinal = value.ordinal,
            .root_layout_node_id = root_layout_node_id.?,
        });
        root_layout_node_id = null;
    }

    var tabs: std.ArrayList(TabRecord) = .empty;
    errdefer {
        for (tabs.items) |value| value.deinit(alloc);
        tabs.deinit(alloc);
    }

    for (runtime.tabs.items) |value| {
        var title_override: ?[]u8 = if (value.title_override) |override|
            try alloc.dupe(u8, override)
        else
            null;
        errdefer if (title_override) |override| alloc.free(override);
        try tabs.append(alloc, .{
            .tab_id = value.tab_id,
            .ordinal = value.ordinal,
            .title_override = title_override,
        });
        title_override = null;
    }

    var layout: std.ArrayList(LayoutNodeRecord) = .empty;
    errdefer {
        for (layout.items) |value| value.deinit(alloc);
        layout.deinit(alloc);
    }

    for (runtime.layout.items) |value| {
        var layout_node_id: ?[]u8 = try alloc.dupe(u8, value.layout_node_id);
        errdefer if (layout_node_id) |id| alloc.free(id);
        var child_ids: ?[]const []const u8 = if (value.child_ids.len > 0)
            try cloneStringSliceAlloc(alloc, value.child_ids)
        else
            null;
        errdefer if (child_ids) |child_id_slice| {
            for (child_id_slice) |child_id| alloc.free(child_id);
            alloc.free(child_id_slice);
        };
        try layout.append(alloc, .{
            .layout_node_id = layout_node_id.?,
            .tab_id = value.tab_id,
            .node_type = model.SnapshotNodeType.fromRuntime(value.node_type) orelse unreachable,
            .split_direction = value.split_direction,
            .ratio = value.ratio,
            .child_ids = child_ids,
            .session_id = value.session_id,
            .is_zoomed = value.is_zoomed,
            .is_selected = value.is_selected,
        });
        layout_node_id = null;
        child_ids = null;
    }

    var sessions: std.ArrayList(SessionRecord) = .empty;
    errdefer {
        for (sessions.items) |value| value.deinit(alloc);
        sessions.deinit(alloc);
    }

    for (runtime.sessions.items) |value| {
        var cwd: ?[]u8 = try alloc.dupe(u8, value.cwd);
        errdefer if (cwd) |value_cwd| alloc.free(value_cwd);
        var command: ?model.Command = try cloneCommandAlloc(alloc, value.command);
        errdefer switch (command.?) {
            .argv => |argv| {
                for (argv) |arg| alloc.free(arg);
                alloc.free(argv);
            },
            .shell => |shell| alloc.free(shell),
        };
        var env_overrides: ?[]const model.EnvOverride = try cloneEnvOverridesAlloc(alloc, value.env_overrides);
        errdefer if (env_overrides) |overrides| {
            for (overrides) |item| {
                alloc.free(item.key);
                alloc.free(item.value);
            }
            alloc.free(overrides);
        };
        var title_override: ?[]u8 = if (value.title_override) |override|
            try alloc.dupe(u8, override)
        else
            null;
        errdefer if (title_override) |override| alloc.free(override);
        try sessions.append(alloc, .{
            .session_id = value.session_id,
            .tab_id = value.tab_id,
            .cwd = cwd.?,
            .command = command.?,
            .env_overrides = env_overrides.?,
            .title_override = title_override,
            .focus_preferred = runtime.workspace.selected_session_id != null and
                runtime.workspace.selected_session_id.? == value.session_id,
        });
        cwd = null;
        command = null;
        env_overrides = null;
        title_override = null;
    }

    const owned_saved_at = try alloc.dupe(u8, saved_at);
    errdefer alloc.free(owned_saved_at);
    const owned_workspace_key = try alloc.dupe(u8, runtime.workspace.slug);
    errdefer alloc.free(owned_workspace_key);
    const owned_name = try alloc.dupe(u8, runtime.workspace.name);
    errdefer alloc.free(owned_name);
    const owned_layout_root_node_id = if (runtime.workspace.layout_root_id) |layout_root_node_id|
        try alloc.dupe(u8, layout_root_node_id)
    else
        null;
    errdefer if (owned_layout_root_node_id) |layout_root_node_id| alloc.free(layout_root_node_id);

    const owned_splits = try splits.toOwnedSlice(alloc);
    splits = .empty;
    errdefer {
        for (owned_splits) |split| split.deinit(alloc);
        alloc.free(owned_splits);
    }
    const owned_tabs = try tabs.toOwnedSlice(alloc);
    tabs = .empty;
    errdefer {
        for (owned_tabs) |tab| tab.deinit(alloc);
        alloc.free(owned_tabs);
    }
    const owned_layout = try layout.toOwnedSlice(alloc);
    layout = .empty;
    errdefer {
        for (owned_layout) |entry| entry.deinit(alloc);
        alloc.free(owned_layout);
    }
    const owned_sessions = try sessions.toOwnedSlice(alloc);
    sessions = .empty;
    errdefer {
        for (owned_sessions) |session| session.deinit(alloc);
        alloc.free(owned_sessions);
    }

    return .{
        .snapshot_id = snapshot_id,
        .saved_at = owned_saved_at,
        .workspace = .{
            .workspace_id = runtime.workspace.workspace_id,
            .workspace_key = owned_workspace_key,
            .name = owned_name,
            .layout_root_node_id = owned_layout_root_node_id,
            .selected_window_id = runtime.workspace.selected_window_id,
            .selected_split_id = runtime.workspace.selected_split_id,
            .selected_tab_id = runtime.workspace.selected_tab_id,
            .selected_session_id = runtime.workspace.selected_session_id,
        },
        .splits = owned_splits,
        .tabs = owned_tabs,
        .layout = owned_layout,
        .sessions = owned_sessions,
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
        const copy = try alloc.dupe(u8, value);
        owned.append(alloc, copy) catch |err| {
            alloc.free(copy);
            return err;
        };
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
        owned[index] = try cloneEnvOverrideAlloc(alloc, value);
        initialized += 1;
    }

    return owned;
}

fn cloneEnvOverrideAlloc(
    alloc: std.mem.Allocator,
    value: model.EnvOverride,
) !model.EnvOverride {
    const key = try alloc.dupe(u8, value.key);
    errdefer alloc.free(key);
    const copied_value = try alloc.dupe(u8, value.value);
    errdefer alloc.free(copied_value);
    return .{ .key = key, .value = copied_value };
}

fn collectReachableSplitRoots(
    alloc: std.mem.Allocator,
    layout: []const LayoutNodeRecord,
    layout_map: *const std.StringHashMap(usize),
    reachable_split_roots: *std.StringHashMap(void),
    layout_node_id: []const u8,
) !void {
    var visited = std.StringHashMap(void).init(alloc);
    defer visited.deinit();
    var pending: std.ArrayList([]const u8) = .empty;
    defer pending.deinit(alloc);
    try pending.append(alloc, layout_node_id);

    while (pending.pop()) |pending_id| {
        const visited_gop = try visited.getOrPut(pending_id);
        if (visited_gop.found_existing) continue;
        const entry = layout[
            layout_map.get(pending_id) orelse return error.LayoutChildMissing
        ];
        switch (entry.node_type) {
            .split_root => {
                _ = try reachable_split_roots.getOrPut(entry.layout_node_id);
            },
            .split => {
                if (entry.tab_id != null) {
                    return error.WorkspaceLayoutChildInvalid;
                }
                const child_ids = entry.child_ids orelse
                    return error.LayoutNodeMissingChildren;
                try pending.appendSlice(alloc, child_ids);
            },
            else => return error.WorkspaceLayoutChildInvalid,
        }
    }
}

fn validateLayoutAcyclic(
    alloc: std.mem.Allocator,
    layout: []const LayoutNodeRecord,
    layout_map: *const std.StringHashMap(usize),
) !void {
    const incoming = try alloc.alloc(usize, layout.len);
    defer alloc.free(incoming);
    @memset(incoming, 0);
    const depth = try alloc.alloc(usize, layout.len);
    defer alloc.free(depth);
    @memset(depth, 1);

    for (layout) |entry| {
        const child_ids = entry.child_ids orelse continue;
        for (child_ids) |child_id| {
            const child_index = layout_map.get(child_id) orelse
                return error.LayoutChildMissing;
            if (incoming[child_index] != 0) {
                return error.LayoutNodeMultipleParents;
            }
            incoming[child_index] = std.math.add(
                usize,
                incoming[child_index],
                1,
            ) catch return error.LayoutChildCountOverflow;
        }
    }

    const pending = try alloc.alloc(usize, layout.len);
    defer alloc.free(pending);
    var pending_read: usize = 0;
    var pending_len: usize = 0;
    for (incoming, 0..) |count, index| {
        if (count == 0) {
            pending[pending_len] = index;
            pending_len += 1;
        }
    }

    while (pending_read < pending_len) : (pending_read += 1) {
        const entry = layout[pending[pending_read]];
        const child_ids = entry.child_ids orelse continue;
        for (child_ids) |child_id| {
            const child_index = layout_map.get(child_id).?;
            const child_depth = std.math.add(
                usize,
                depth[pending[pending_read]],
                1,
            ) catch return error.LayoutDepthExceeded;
            depth[child_index] = @max(depth[child_index], child_depth);
            if (depth[child_index] > max_layout_depth) {
                return error.LayoutDepthExceeded;
            }
            incoming[child_index] -= 1;
            if (incoming[child_index] == 0) {
                pending[pending_len] = child_index;
                pending_len += 1;
            }
        }
    }

    if (pending_len != layout.len) return error.LayoutCycle;
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
        const workspace_key = if (self.workspace_key) |workspace_key|
            try alloc.dupe(u8, workspace_key)
        else
            null;
        errdefer if (workspace_key) |key| alloc.free(key);
        const workspace_name = try alloc.dupe(u8, self.workspace_name);
        errdefer alloc.free(workspace_name);
        const saved_at = try alloc.dupe(u8, self.saved_at);
        errdefer alloc.free(saved_at);
        const path = try alloc.dupe(u8, self.path);
        errdefer alloc.free(path);
        return .{
            .snapshot_id = self.snapshot_id,
            .workspace_id = self.workspace_id,
            .workspace_key = workspace_key,
            .workspace_name = workspace_name,
            .saved_at = saved_at,
            .path = path,
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
    const workspace_key = if (value.workspace.workspace_key) |workspace_key|
        try alloc.dupe(u8, workspace_key)
    else
        null;
    errdefer if (workspace_key) |key| alloc.free(key);
    const workspace_name = try alloc.dupe(u8, value.workspace.name);
    errdefer alloc.free(workspace_name);
    const saved_at = try alloc.dupe(u8, value.saved_at);
    errdefer alloc.free(saved_at);
    const path_copy = try alloc.dupe(u8, path);
    errdefer alloc.free(path_copy);
    return .{
        .snapshot_id = value.snapshot_id,
        .workspace_id = value.workspace.workspace_id,
        .workspace_key = workspace_key,
        .workspace_name = workspace_name,
        .saved_at = saved_at,
        .path = path_copy,
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
        const parsed = try std.json.parseFromSlice(Catalog, alloc, data, .{
            .allocate = .alloc_always,
        });
        defer parsed.deinit();
        if (parsed.value.version != current_version) {
            return error.InvalidSnapshotVersion;
        }

        const entries = try alloc.alloc(CatalogEntry, parsed.value.entries.len);
        var initialized: usize = 0;
        errdefer {
            for (entries[0..initialized]) |entry| entry.deinit(alloc);
            alloc.free(entries);
        }

        for (parsed.value.entries, 0..) |entry, i| {
            entries[i] = try entry.cloneAlloc(alloc);
            initialized += 1;
        }

        return .{
            .version = parsed.value.version,
            .entries = entries,
        };
    }

    pub fn deinit(self: Catalog, alloc: std.mem.Allocator) void {
        for (self.entries) |entry| entry.deinit(alloc);
        if (self.entries.len > 0) alloc.free(self.entries);
    }
};

fn testCloneSnapshotCollectionsAllocation(alloc: std.mem.Allocator) !void {
    const strings = try cloneStringSliceAlloc(alloc, &.{ "one", "two", "three" });
    defer {
        for (strings) |value| alloc.free(value);
        alloc.free(strings);
    }

    const overrides = try cloneEnvOverridesAlloc(alloc, &.{
        .{ .key = "ONE", .value = "1" },
        .{ .key = "TWO", .value = "2" },
    });
    defer {
        for (overrides) |item| {
            alloc.free(item.key);
            alloc.free(item.value);
        }
        alloc.free(overrides);
    }
}

test "workspace snapshot collection clones clean up allocation failures" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        testCloneSnapshotCollectionsAllocation,
        .{},
    );
}

fn testLayoutDepth(alloc: std.mem.Allocator, node_count: usize) !void {
    const node_ids = try alloc.alloc([]u8, node_count);
    var initialized_ids: usize = 0;
    defer {
        for (node_ids[0..initialized_ids]) |id| alloc.free(id);
        alloc.free(node_ids);
    }
    for (node_ids, 0..) |*id, index| {
        id.* = try std.fmt.allocPrint(alloc, "node-{d}", .{index});
        initialized_ids += 1;
    }

    const child_refs = try alloc.alloc([]const u8, node_count - 1);
    defer alloc.free(child_refs);
    for (child_refs, 0..) |*child_id, index| {
        child_id.* = node_ids[index + 1];
    }

    const layout = try alloc.alloc(LayoutNodeRecord, node_count);
    defer alloc.free(layout);
    for (layout, 0..) |*node, index| {
        node.* = .{
            .layout_node_id = node_ids[index],
            .node_type = if (index + 1 == node_count)
                .session_leaf
            else
                .split,
            .split_direction = if (index + 1 == node_count) null else .right,
            .child_ids = if (index + 1 == node_count)
                null
            else
                child_refs[index .. index + 1],
        };
    }

    var layout_map = std.StringHashMap(usize).init(alloc);
    defer layout_map.deinit();
    for (layout, 0..) |node, index| {
        try layout_map.put(node.layout_node_id, index);
    }
    try validateLayoutAcyclic(alloc, layout, &layout_map);
}

test "workspace snapshot layout depth is bounded before restore" {
    try testLayoutDepth(std.testing.allocator, max_layout_depth);
    try std.testing.expectError(
        error.LayoutDepthExceeded,
        testLayoutDepth(std.testing.allocator, max_layout_depth + 1),
    );
}

test {
    _ = @import("workspace_snapshot_test.zig");
}
