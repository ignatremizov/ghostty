const std = @import("std");
const ids = @import("workspace_ids.zig");
const model = @import("workspace_model.zig");
const snapshot = @import("workspace_snapshot.zig");

pub const SurfaceAction = enum {
    realize_replacement_surface,
};

pub const ScrollbackPolicy = enum {
    do_not_restore,
};

pub const SelectionHints = struct {
    selected_window_id: ?ids.WindowId = null,
    selected_split_id: ?ids.SplitId = null,
    selected_tab_id: ?ids.TabId = null,
    selected_session_id: ?ids.SessionId = null,
};

pub const SplitPlan = struct {
    split_id: ids.SplitId,
    ordinal: usize,
    tab_start: usize,
    tab_len: usize,
    preferred_window_id: ?ids.WindowId = null,
    layout_root_id: ?[]const u8 = null,
    selected_hint: bool = false,
};

pub const TabPlan = struct {
    split_id: ids.SplitId,
    tab_id: ids.TabId,
    ordinal: usize,
    ordinal_in_split: usize,
    root_layout_node_id: []const u8,
    title_override: ?[]const u8 = null,
    session_start: usize,
    session_len: usize,
    selected_hint: bool = false,
};

pub const SessionPlan = struct {
    session_id: ids.SessionId,
    split_id: ids.SplitId,
    tab_id: ids.TabId,
    layout_node_id: []const u8,
    split_ordinal: usize,
    tab_ordinal: usize,
    session_ordinal: usize,
    cwd: []const u8,
    command: model.Command,
    env_overrides: []const model.EnvOverride = &.{},
    title_override: ?[]const u8 = null,
    focus_preferred: bool = false,
    surface_action: SurfaceAction = .realize_replacement_surface,
    scrollback_policy: ScrollbackPolicy = .do_not_restore,
};

pub const Plan = struct {
    snapshot_id: ids.SnapshotId,
    workspace_id: ids.WorkspaceId,
    workspace_name: []const u8,
    selection_hints: SelectionHints,
    splits: []SplitPlan,
    tabs: []TabPlan,
    tab_order: []usize,
    sessions: []SessionPlan,

    pub fn deinit(self: Plan, alloc: std.mem.Allocator) void {
        alloc.free(self.splits);
        alloc.free(self.tabs);
        alloc.free(self.tab_order);
        alloc.free(self.sessions);
    }
};

pub const RestoredPlacement = struct {
    session_id: ids.SessionId,
    window_id: ids.WindowId,
    split_id: ids.SplitId,
    tab_id: ids.TabId,
    surface_action: SurfaceAction = .realize_replacement_surface,
};

pub const ReplayFailure = struct {
    session_id: ids.SessionId,
    code: model.RestoreFailureCode,
    message: ?[]const u8 = null,
};

pub const ReplayOutcome = union(enum) {
    restored: RestoredPlacement,
    failed: ReplayFailure,
};

pub const SelectionResolution = struct {
    window_id: ?ids.WindowId = null,
    split_id: ?ids.SplitId = null,
    tab_id: ?ids.TabId = null,
    session_id: ?ids.SessionId = null,
    fallback_reason: ?model.SelectionFallbackReason = null,
};

pub const FinalizedRestore = struct {
    selection: SelectionResolution = .{},
    results: model.RestoreResults,

    pub fn deinit(self: FinalizedRestore, alloc: std.mem.Allocator) void {
        alloc.free(self.results.restored_session_ids);
        for (self.results.failed_sessions) |failure| {
            alloc.free(failure.code);
            alloc.free(failure.message);
        }
        alloc.free(self.results.failed_sessions);
        if (self.results.selection_fallback) |selection_fallback| {
            alloc.free(selection_fallback.reason);
        }
    }
};

const VisitState = enum {
    visiting,
    done,
};

const ReplayScope = struct {
    window_id: ?ids.WindowId = null,
    split_id: ?ids.SplitId = null,
    tab_id: ?ids.TabId = null,
    session_id: ?ids.SessionId = null,
};

pub fn planAlloc(
    alloc: std.mem.Allocator,
    value: snapshot.Snapshot,
) !Plan {
    try value.validate();

    var tab_map = std.AutoHashMap(ids.TabId, snapshot.TabRecord).init(alloc);
    defer tab_map.deinit();
    for (value.tabs) |tab| {
        const gop = try tab_map.getOrPut(tab.tab_id);
        if (gop.found_existing) return error.DuplicateTabId;
        gop.value_ptr.* = tab;
    }

    var session_map = std.AutoHashMap(ids.SessionId, snapshot.SessionRecord).init(alloc);
    defer session_map.deinit();
    for (value.sessions) |session| {
        const gop = try session_map.getOrPut(session.session_id);
        if (gop.found_existing) return error.DuplicateSessionId;
        gop.value_ptr.* = session;
    }

    var layout_map = std.StringHashMap(snapshot.LayoutNodeRecord).init(alloc);
    defer layout_map.deinit();
    for (value.layout) |node| {
        const gop = try layout_map.getOrPut(node.layout_node_id);
        if (gop.found_existing) return error.DuplicateLayoutNodeId;
        gop.value_ptr.* = node;
    }

    const ordered_splits = try validateAndSortSplits(
        alloc,
        value,
        &tab_map,
        &session_map,
    );
    defer alloc.free(ordered_splits);

    var split_plans = try alloc.alloc(SplitPlan, ordered_splits.len);
    errdefer alloc.free(split_plans);
    var tab_plans: std.ArrayList(TabPlan) = .empty;
    defer tab_plans.deinit(alloc);
    var session_plans: std.ArrayList(SessionPlan) = .empty;
    defer session_plans.deinit(alloc);

    var visit_states = std.StringHashMap(VisitState).init(alloc);
    defer visit_states.deinit();
    var seen_sessions = std.AutoHashMap(ids.SessionId, void).init(alloc);
    defer seen_sessions.deinit();

    for (ordered_splits, 0..) |split, split_ordinal| {
        const tab_start = tab_plans.items.len;
        const split_tabs = try sortedSplitTabsAlloc(alloc, split, value.tabs, value.layout);
        defer alloc.free(split_tabs);
        if (split_tabs.len == 0) return error.SplitRequiresTab;

        for (split_tabs, 0..) |tab, ordinal_in_split| {
            visit_states.clearRetainingCapacity();
            seen_sessions.clearRetainingCapacity();

            const root_layout_node_id = try snapshot.resolveTabRootLayoutNodeId(tab.tab_id, value.layout);
            const root_node = layout_map.get(root_layout_node_id) orelse return error.TabRootMissing;
            if (root_node.node_type != .tab_root) return error.TabRootNodeTypeMismatch;
            if (root_node.tab_id != tab.tab_id) return error.TabRootOutsideTab;

            const session_start = session_plans.items.len;
            try visitLayoutNode(
                alloc,
                split.split_id,
                split_ordinal,
                tab.tab_id,
                root_node.layout_node_id,
                &layout_map,
                &session_map,
                &visit_states,
                &seen_sessions,
                tab.ordinal,
                session_start,
                &session_plans,
                value.workspace.selected_session_id,
            );
            try ensureAllTabSessionsReachable(
                tab.tab_id,
                value.sessions,
                &seen_sessions,
            );

            try tab_plans.append(alloc, .{
                .split_id = split.split_id,
                .tab_id = tab.tab_id,
                .ordinal = tab.ordinal,
                .ordinal_in_split = ordinal_in_split,
                .root_layout_node_id = root_layout_node_id,
                .title_override = tab.title_override,
                .session_start = session_start,
                .session_len = session_plans.items.len - session_start,
                .selected_hint = value.workspace.selected_tab_id != null and
                    value.workspace.selected_tab_id.? == tab.tab_id,
            });
        }

        split_plans[split_ordinal] = .{
            .split_id = split.split_id,
            .ordinal = split.ordinal,
            .tab_start = tab_start,
            .tab_len = tab_plans.items.len - tab_start,
            .preferred_window_id = split.window_id,
            .layout_root_id = split.root_layout_node_id,
            .selected_hint = value.workspace.selected_split_id != null and
                value.workspace.selected_split_id.? == split.split_id,
        };
    }

    const owned_tabs = try tab_plans.toOwnedSlice(alloc);
    errdefer alloc.free(owned_tabs);
    const tab_order = try globalTabOrderAlloc(alloc, owned_tabs);
    errdefer alloc.free(tab_order);

    return .{
        .snapshot_id = value.snapshot_id,
        .workspace_id = value.workspace.workspace_id,
        .workspace_name = value.workspace.name,
        .selection_hints = .{
            .selected_window_id = value.workspace.selected_window_id,
            .selected_split_id = value.workspace.selected_split_id,
            .selected_tab_id = value.workspace.selected_tab_id,
            .selected_session_id = value.workspace.selected_session_id,
        },
        .splits = split_plans,
        .tabs = owned_tabs,
        .tab_order = tab_order,
        .sessions = try session_plans.toOwnedSlice(alloc),
    };
}

pub fn finalizeAlloc(
    alloc: std.mem.Allocator,
    plan: *const Plan,
    outcomes: []const ReplayOutcome,
) !FinalizedRestore {
    var outcome_map = std.AutoHashMap(ids.SessionId, ReplayOutcome).init(alloc);
    defer outcome_map.deinit();

    for (outcomes) |outcome| {
        const session_id = switch (outcome) {
            .restored => |restored| restored.session_id,
            .failed => |failed| failed.session_id,
        };
        const gop = try outcome_map.getOrPut(session_id);
        if (gop.found_existing) return error.DuplicateReplayOutcome;
        gop.value_ptr.* = outcome;
    }

    var restored_ids: std.ArrayList(ids.SessionId) = .empty;
    defer restored_ids.deinit(alloc);
    var restored_placements: std.ArrayList(RestoredPlacement) = .empty;
    defer restored_placements.deinit(alloc);
    var failed_sessions: std.ArrayList(model.RestoreFailure) = .empty;
    defer {
        freeRestoreFailures(alloc, failed_sessions.items);
        failed_sessions.deinit(alloc);
    }

    for (plan.sessions) |session| {
        const outcome = outcome_map.get(session.session_id) orelse return error.MissingReplayOutcome;
        switch (outcome) {
            .restored => |restored| {
                try restored_ids.append(alloc, restored.session_id);
                try restored_placements.append(alloc, restored);
            },
            .failed => |failed| {
                var code: ?[]u8 = try alloc.dupe(u8, failed.code.code());
                errdefer if (code) |value| alloc.free(value);
                var message: ?[]u8 = if (failed.message) |message|
                    try alloc.dupe(u8, message)
                else
                    try alloc.dupe(u8, failed.code.message());
                errdefer if (message) |value| alloc.free(value);
                try failed_sessions.append(alloc, .{
                    .session_id = failed.session_id,
                    .code = code.?,
                    .message = message.?,
                });
                code = null;
                message = null;
            },
        }
    }
    if (outcome_map.count() != plan.sessions.len) return error.UnknownReplayOutcomeSession;

    const selection = resolveSelection(plan, restored_placements.items);
    const selection_fallback = try allocSelectionFallback(alloc, selection);
    errdefer if (selection_fallback) |value| alloc.free(value.reason);

    const restored_session_ids = try restored_ids.toOwnedSlice(alloc);
    errdefer alloc.free(restored_session_ids);
    const owned_failed_sessions = try failed_sessions.toOwnedSlice(alloc);
    failed_sessions = .empty;
    errdefer {
        freeRestoreFailures(alloc, owned_failed_sessions);
        alloc.free(owned_failed_sessions);
    }

    return .{
        .selection = selection,
        .results = .{
            .restored_workspace_id = plan.workspace_id,
            .restored_session_ids = restored_session_ids,
            .failed_sessions = owned_failed_sessions,
            .selection_fallback = selection_fallback,
        },
    };
}

fn validateAndSortSplits(
    alloc: std.mem.Allocator,
    value: snapshot.Snapshot,
    tab_map: *const std.AutoHashMap(ids.TabId, snapshot.TabRecord),
    session_map: *const std.AutoHashMap(ids.SessionId, snapshot.SessionRecord),
) ![]snapshot.SplitRecord {
    var split_map = std.AutoHashMap(ids.SplitId, snapshot.SplitRecord).init(alloc);
    defer split_map.deinit();
    var tab_assignment = std.AutoHashMap(ids.TabId, ids.SplitId).init(alloc);
    defer tab_assignment.deinit();

    for (value.splits) |split| {
        const gop = try split_map.getOrPut(split.split_id);
        if (gop.found_existing) return error.DuplicateSplitId;
        gop.value_ptr.* = split;

        const split_tab_ids = try snapshot.resolveSplitTabIdsAlloc(alloc, split, value.layout);
        defer alloc.free(split_tab_ids);
        if (split_tab_ids.len == 0) return error.SplitRequiresTab;
        for (split_tab_ids) |tab_id| {
            if (!tab_map.contains(tab_id)) return error.SplitTabMissing;
            const tab_gop = try tab_assignment.getOrPut(tab_id);
            if (tab_gop.found_existing) return error.TabAssignedToMultipleSplits;
            tab_gop.value_ptr.* = split.split_id;
        }
    }

    for (value.tabs) |tab| {
        if (!tab_assignment.contains(tab.tab_id)) return error.TabMissingSplit;
    }

    try validateSelectionContext(value.workspace, &split_map, &tab_assignment, tab_map, session_map);

    const ordered = try alloc.dupe(snapshot.SplitRecord, value.splits);
    std.mem.sortUnstable(snapshot.SplitRecord, ordered, {}, struct {
        fn lessThan(_: void, a: snapshot.SplitRecord, b: snapshot.SplitRecord) bool {
            if (a.ordinal != b.ordinal) return a.ordinal < b.ordinal;
            return a.split_id.raw() < b.split_id.raw();
        }
    }.lessThan);
    return ordered;
}

fn validateSelectionContext(
    value: snapshot.WorkspaceSelection,
    split_map: *const std.AutoHashMap(ids.SplitId, snapshot.SplitRecord),
    tab_assignment: *const std.AutoHashMap(ids.TabId, ids.SplitId),
    tab_map: *const std.AutoHashMap(ids.TabId, snapshot.TabRecord),
    session_map: *const std.AutoHashMap(ids.SessionId, snapshot.SessionRecord),
) !void {
    if (value.selected_session_id != null and value.selected_tab_id == null) {
        return error.SelectedSessionRequiresTab;
    }
    if (value.selected_tab_id != null and value.selected_split_id == null) {
        return error.SelectedTabRequiresSplit;
    }
    if (value.selected_split_id != null and value.selected_window_id == null) {
        return error.SelectedSplitRequiresWindow;
    }

    if (value.selected_split_id) |selected_split_id| {
        if (!split_map.contains(selected_split_id)) return error.SelectedSplitNotFound;
    }

    if (value.selected_tab_id) |selected_tab_id| {
        if (!tab_map.contains(selected_tab_id)) return error.SelectedTabNotFound;
        const owning_split_id = tab_assignment.get(selected_tab_id) orelse return error.SelectedTabNotFound;
        if (owning_split_id != value.selected_split_id.?) return error.SelectedTabOutsideSplit;
    }

    if (value.selected_session_id) |selected_session_id| {
        const session = session_map.get(selected_session_id) orelse return error.SelectedSessionNotFound;
        if (value.selected_tab_id.? != session.tab_id) return error.SelectedSessionOutsideTab;
    }
}

fn sortedSplitTabsAlloc(
    alloc: std.mem.Allocator,
    split: snapshot.SplitRecord,
    tabs_src: []const snapshot.TabRecord,
    layout: []const snapshot.LayoutNodeRecord,
) ![]snapshot.TabRecord {
    const split_tab_ids = try snapshot.resolveSplitTabIdsAlloc(alloc, split, layout);
    defer alloc.free(split_tab_ids);

    var tabs = try alloc.alloc(snapshot.TabRecord, split_tab_ids.len);
    errdefer alloc.free(tabs);

    for (split_tab_ids, 0..) |tab_id, index| {
        tabs[index] = findTabRecord(tabs_src, tab_id) orelse return error.SplitTabMissing;
    }

    std.mem.sortUnstable(snapshot.TabRecord, tabs, {}, struct {
        fn lessThan(_: void, a: snapshot.TabRecord, b: snapshot.TabRecord) bool {
            if (a.ordinal != b.ordinal) return a.ordinal < b.ordinal;
            return a.tab_id.raw() < b.tab_id.raw();
        }
    }.lessThan);

    return tabs;
}

fn findTabRecord(
    tabs: []const snapshot.TabRecord,
    tab_id: ids.TabId,
) ?snapshot.TabRecord {
    for (tabs) |tab| {
        if (tab.tab_id == tab_id) return tab;
    }
    return null;
}

fn visitLayoutNode(
    alloc: std.mem.Allocator,
    split_id: ids.SplitId,
    split_ordinal: usize,
    tab_id: ids.TabId,
    layout_node_id: []const u8,
    layout_map: *const std.StringHashMap(snapshot.LayoutNodeRecord),
    session_map: *const std.AutoHashMap(ids.SessionId, snapshot.SessionRecord),
    visit_states: *std.StringHashMap(VisitState),
    seen_sessions: *std.AutoHashMap(ids.SessionId, void),
    tab_ordinal: usize,
    session_start: usize,
    session_plans: *std.ArrayList(SessionPlan),
    selected_session_id: ?ids.SessionId,
) !void {
    const gop = try visit_states.getOrPut(layout_node_id);
    if (gop.found_existing) {
        return switch (gop.value_ptr.*) {
            .visiting => error.LayoutCycle,
            .done => {},
        };
    }
    gop.value_ptr.* = .visiting;

    const node = layout_map.get(layout_node_id) orelse return error.LayoutNodeMissing;
    if (node.tab_id != tab_id) return error.LayoutNodeOutsideTab;

    switch (node.node_type) {
        .split_root => return error.LayoutChildCrossesSplitRootBoundary,
        .tab_root => {
            const child_ids = node.child_ids orelse return error.TabRootRequiresChildren;
            if (child_ids.len == 0) return error.TabRootRequiresChildren;
            for (child_ids) |child_id| {
                try visitLayoutNode(
                    alloc,
                    split_id,
                    split_ordinal,
                    tab_id,
                    child_id,
                    layout_map,
                    session_map,
                    visit_states,
                    seen_sessions,
                    tab_ordinal,
                    session_start,
                    session_plans,
                    selected_session_id,
                );
            }
        },
        .split => {
            const child_ids = node.child_ids orelse return error.SplitRequiresChildrenAndDirection;
            if (child_ids.len == 0) return error.SplitRequiresChildrenAndDirection;
            for (child_ids) |child_id| {
                try visitLayoutNode(
                    alloc,
                    split_id,
                    split_ordinal,
                    tab_id,
                    child_id,
                    layout_map,
                    session_map,
                    visit_states,
                    seen_sessions,
                    tab_ordinal,
                    session_start,
                    session_plans,
                    selected_session_id,
                );
            }
        },
        .session_leaf => {
            const session_id = node.session_id orelse return error.SessionLeafRequiresSessionId;
            const session = session_map.get(session_id) orelse return error.SessionMissingRecord;
            if (session.tab_id != tab_id) return error.SessionOutsideTab;
            const seen = try seen_sessions.getOrPut(session_id);
            if (seen.found_existing) return error.DuplicateSessionInLayout;
            try session_plans.append(alloc, .{
                .session_id = session.session_id,
                .split_id = split_id,
                .tab_id = session.tab_id,
                .layout_node_id = node.layout_node_id,
                .split_ordinal = split_ordinal,
                .tab_ordinal = tab_ordinal,
                .session_ordinal = session_plans.items.len - session_start,
                .cwd = session.cwd,
                .command = session.command,
                .env_overrides = session.env_overrides,
                .title_override = session.title_override,
                .focus_preferred = session.focus_preferred or
                    (selected_session_id != null and selected_session_id.? == session.session_id),
            });
        },
    }

    gop.value_ptr.* = .done;
}

fn ensureAllTabSessionsReachable(
    tab_id: ids.TabId,
    sessions: []const snapshot.SessionRecord,
    seen_sessions: *const std.AutoHashMap(ids.SessionId, void),
) !void {
    for (sessions) |session| {
        if (session.tab_id != tab_id) continue;
        if (!seen_sessions.contains(session.session_id)) return error.SessionMissingFromLayout;
    }
}

fn freeRestoreFailures(
    alloc: std.mem.Allocator,
    failures: []const model.RestoreFailure,
) void {
    for (failures) |failure| {
        alloc.free(failure.code);
        alloc.free(failure.message);
    }
}

fn allocSelectionFallback(
    alloc: std.mem.Allocator,
    selection: SelectionResolution,
) !?model.SelectionFallback {
    const reason = selection.fallback_reason orelse return null;
    return .{
        .window_id = selection.window_id.?,
        .tab_id = selection.tab_id.?,
        .session_id = selection.session_id.?,
        .reason = try alloc.dupe(u8, reason.code()),
    };
}

fn resolveSelection(
    plan: *const Plan,
    placements: []const RestoredPlacement,
) SelectionResolution {
    if (placements.len == 0) return .{};

    var scope: ReplayScope = .{};

    if (plan.selection_hints.selected_window_id) |selected_window_id| {
        if (firstPlacement(placements, .{ .window_id = selected_window_id }) == null) {
            const fallback_window_id = firstSurvivingWindowInTabOrder(plan, placements) orelse return .{};
            return selectionFromPlacement(firstPlacementInTabOrder(
                plan,
                placements,
                .{ .window_id = fallback_window_id },
            ).?, .selected_window_missing);
        }
        scope.window_id = selected_window_id;
    }

    if (plan.selection_hints.selected_split_id) |selected_split_id| {
        if (firstPlacementInTabOrder(plan, placements, withSplit(scope, selected_split_id)) == null) {
            return selectionFromPlacement(firstPlacementInTabOrder(plan, placements, scope).?, .selected_split_missing);
        }
        scope.split_id = selected_split_id;
    }

    if (plan.selection_hints.selected_tab_id) |selected_tab_id| {
        if (firstPlacementInTabOrder(plan, placements, withTab(scope, selected_tab_id)) == null) {
            return selectionFromPlacement(firstPlacementInTabOrder(plan, placements, scope).?, .selected_tab_missing);
        }
        scope.tab_id = selected_tab_id;
    }

    if (plan.selection_hints.selected_session_id) |selected_session_id| {
        if (firstPlacementInTabOrder(plan, placements, withSession(scope, selected_session_id)) == null) {
            return selectionFromPlacement(firstPlacementInTabOrder(plan, placements, scope).?, .selected_session_missing);
        }
        scope.session_id = selected_session_id;
    }

    return selectionFromPlacement(firstPlacementInTabOrder(plan, placements, scope).?, null);
}

fn selectionFromPlacement(
    placement: RestoredPlacement,
    reason: ?model.SelectionFallbackReason,
) SelectionResolution {
    return .{
        .window_id = placement.window_id,
        .split_id = placement.split_id,
        .tab_id = placement.tab_id,
        .session_id = placement.session_id,
        .fallback_reason = reason,
    };
}

fn firstPlacement(
    placements: []const RestoredPlacement,
    scope: ReplayScope,
) ?RestoredPlacement {
    for (placements) |placement| {
        if (!matchesScope(placement, scope)) continue;
        return placement;
    }
    return null;
}

fn firstPlacementInTabOrder(
    plan: *const Plan,
    placements: []const RestoredPlacement,
    scope: ReplayScope,
) ?RestoredPlacement {
    for (plan.tab_order) |tab_index| {
        const tab = plan.tabs[tab_index];
        for (plan.sessions[tab.session_start .. tab.session_start + tab.session_len]) |session| {
            const placement = findPlacement(placements, session.session_id) orelse continue;
            if (!matchesScope(placement, scope)) continue;
            return placement;
        }
    }
    return null;
}

fn firstSurvivingWindowInTabOrder(
    plan: *const Plan,
    placements: []const RestoredPlacement,
) ?ids.WindowId {
    for (plan.tab_order) |tab_index| {
        const tab = plan.tabs[tab_index];
        for (plan.sessions[tab.session_start .. tab.session_start + tab.session_len]) |session| {
            const placement = findPlacement(placements, session.session_id) orelse continue;
            return placement.window_id;
        }
    }
    return null;
}

fn globalTabOrderAlloc(
    alloc: std.mem.Allocator,
    tabs: []const TabPlan,
) ![]usize {
    const order = try alloc.alloc(usize, tabs.len);
    errdefer alloc.free(order);

    for (order, 0..) |*slot, index| slot.* = index;
    std.mem.sortUnstable(usize, order, tabs, struct {
        fn lessThan(context: []const TabPlan, a: usize, b: usize) bool {
            const left = context[a];
            const right = context[b];
            if (left.ordinal != right.ordinal) return left.ordinal < right.ordinal;
            return left.tab_id.raw() < right.tab_id.raw();
        }
    }.lessThan);

    return order;
}

fn findPlacement(
    placements: []const RestoredPlacement,
    session_id: ids.SessionId,
) ?RestoredPlacement {
    for (placements) |placement| {
        if (placement.session_id == session_id) return placement;
    }
    return null;
}

fn matchesScope(
    placement: RestoredPlacement,
    scope: ReplayScope,
) bool {
    if (scope.window_id != null and placement.window_id != scope.window_id.?) return false;
    if (scope.split_id != null and placement.split_id != scope.split_id.?) return false;
    if (scope.tab_id != null and placement.tab_id != scope.tab_id.?) return false;
    if (scope.session_id != null and placement.session_id != scope.session_id.?) return false;
    return true;
}

fn withSplit(scope: ReplayScope, split_id: ids.SplitId) ReplayScope {
    var next = scope;
    next.split_id = split_id;
    return next;
}

fn withTab(scope: ReplayScope, tab_id: ids.TabId) ReplayScope {
    var next = scope;
    next.tab_id = tab_id;
    return next;
}

fn withSession(scope: ReplayScope, session_id: ids.SessionId) ReplayScope {
    var next = scope;
    next.session_id = session_id;
    return next;
}

test {
    _ = @import("workspace_restore_test.zig");
}
