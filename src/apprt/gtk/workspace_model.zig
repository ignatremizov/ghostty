const std = @import("std");
const ids = @import("workspace_ids.zig");
const attention = @import("workspace_attention.zig");

pub const WorkspaceOrigin = enum {
    runtime,
    restored,
    imported,
};

pub const FocusState = enum {
    focused,
    background,
    last_focused,
    detached,
};

pub const ActivityState = enum {
    idle,
    output_pending,
    bell_pending,
    exited,
    restore_failed,
};

pub const NodeType = enum {
    split_root,
    tab,
    split,
    session_leaf,

    pub fn jsonStringify(self: NodeType, writer: anytype) !void {
        try writer.write(switch (self) {
            .split_root => "split-root",
            .tab => "tab",
            .split => "split",
            .session_leaf => "session-leaf",
        });
    }
};

pub const SnapshotNodeType = enum {
    split_root,
    tab_root,
    split,
    session_leaf,

    pub fn fromRuntime(node_type: NodeType) ?SnapshotNodeType {
        return switch (node_type) {
            .split_root => .split_root,
            .tab => .tab_root,
            .split => .split,
            .session_leaf => .session_leaf,
        };
    }

    pub fn jsonStringify(self: SnapshotNodeType, writer: anytype) !void {
        try writer.write(switch (self) {
            .split_root => "split-root",
            .tab_root => "tab-root",
            .split => "split",
            .session_leaf => "session-leaf",
        });
    }

    pub fn jsonParse(
        allocator: std.mem.Allocator,
        source: anytype,
        options: std.json.ParseOptions,
    ) !SnapshotNodeType {
        const token = try source.nextAllocMax(allocator, options.allocate.?, options.max_value_len.?);
        const text = switch (token) {
            .string => |value| value,
            .allocated_string => |value| value,
            else => return error.UnexpectedToken,
        };
        defer switch (token) {
            .allocated_string => allocator.free(text),
            else => {},
        };

        if (std.mem.eql(u8, text, "split-root")) return .split_root;
        if (std.mem.eql(u8, text, "tab-root")) return .tab_root;
        if (std.mem.eql(u8, text, "split")) return .split;
        if (std.mem.eql(u8, text, "session-leaf")) return .session_leaf;
        return error.InvalidEnumTag;
    }
};

pub const SplitDirection = enum {
    right,
    left,
    up,
    down,
};

pub const WorkspaceSnapshotRef = struct {
    snapshot_id: ids.SnapshotId,
    saved_at: []const u8,
    path: []const u8,
};

pub const Workspace = struct {
    workspace_id: ids.WorkspaceId,
    name: []const u8,
    slug: []const u8,
    origin: WorkspaceOrigin,
    selected_window_id: ?ids.WindowId = null,
    selected_split_id: ?ids.SplitId = null,
    selected_tab_id: ?ids.TabId = null,
    selected_session_id: ?ids.SessionId = null,
    split_ids: []const ids.SplitId = &.{},
    session_ids: []const ids.SessionId = &.{},
    tab_ids: []const ids.TabId = &.{},
    attention_summary: attention.AttentionSummary = .{},
    snapshot_ref: ?WorkspaceSnapshotRef = null,
    created_at: []const u8,
    updated_at: []const u8,

    pub fn validateSelection(self: Workspace) !void {
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

pub const WindowRuntime = struct {
    window_id: ids.WindowId,
    workspace_id: ids.WorkspaceId,
    is_active: bool,
    is_quick_terminal: bool,
    split_ids: []const ids.SplitId = &.{},
    last_presented_at: ?[]const u8 = null,
};

pub const SplitRuntime = struct {
    split_id: ids.SplitId,
    workspace_id: ids.WorkspaceId,
    window_id: ids.WindowId,
    title: []const u8,
    ordinal: usize,
    tab_ids: []const ids.TabId = &.{},
    layout_root_id: []const u8,
    needs_attention: bool = false,
};

pub const TabRuntime = struct {
    tab_id: ids.TabId,
    split_id: ids.SplitId,
    workspace_id: ids.WorkspaceId,
    window_id: ids.WindowId,
    title: []const u8,
    title_override: ?[]const u8 = null,
    tooltip: ?[]const u8 = null,
    layout_root_id: []const u8,
    ordinal: usize,
    needs_attention: bool = false,
};

pub const Command = union(enum) {
    argv: []const []const u8,
    shell: []const u8,

    pub fn jsonStringify(self: Command, writer: anytype) !void {
        switch (self) {
            .argv => |argv| try writer.write(argv),
            .shell => |shell| try writer.write(shell),
        }
    }

    pub fn jsonParse(
        allocator: std.mem.Allocator,
        source: anytype,
        options: std.json.ParseOptions,
    ) !Command {
        return switch (try source.peekNextTokenType()) {
            .array_begin => .{ .argv = try std.json.innerParse([]const []const u8, allocator, source, options) },
            .string => .{ .shell = try std.json.innerParse([]const u8, allocator, source, options) },
            else => error.UnexpectedToken,
        };
    }
};

pub const EnvOverride = struct {
    key: []const u8,
    value: []const u8,
};

pub const Session = struct {
    session_id: ids.SessionId,
    workspace_id: ids.WorkspaceId,
    window_id: ids.WindowId,
    tab_id: ids.TabId,
    split_id: ids.SplitId,
    layout_node_id: []const u8,
    title: []const u8,
    title_override: ?[]const u8 = null,
    cwd: []const u8,
    command: Command,
    env_overrides: []const EnvOverride = &.{},
    focus_state: FocusState = .background,
    activity_state: ActivityState = .idle,
    last_output_at: ?[]const u8 = null,
    last_focus_at: ?[]const u8 = null,
    exit_status: ?u32 = null,
    restore_error_code: ?[]const u8 = null,
    restore_error_message: ?[]const u8 = null,
};

pub const SurfaceRuntime = struct {
    surface_id: ids.SurfaceId,
    session_id: ids.SessionId,
    tab_id: ids.TabId,
    split_id: ids.SplitId,
    window_id: ids.WindowId,
    is_realized: bool,
    last_bell_at: ?[]const u8 = null,
    last_output_at: ?[]const u8 = null,
};

pub const LayoutNode = struct {
    layout_node_id: []const u8,
    workspace_id: ids.WorkspaceId,
    split_id: ids.SplitId,
    tab_id: ?ids.TabId = null,
    node_type: NodeType,
    split_direction: ?SplitDirection = null,
    ratio: ?f64 = null,
    child_ids: []const []const u8 = &.{},
    session_id: ?ids.SessionId = null,
    is_zoomed: bool = false,
    is_selected: bool = false,
};

pub const RestoreFailureCode = enum {
    cwd_missing,
    command_missing,
    launch_recipe_invalid,
    session_tab_missing,
    session_layout_missing,
    replacement_surface_failed,

    pub fn code(self: RestoreFailureCode) []const u8 {
        return switch (self) {
            .cwd_missing => "cwd_missing",
            .command_missing => "command_missing",
            .launch_recipe_invalid => "launch_recipe_invalid",
            .session_tab_missing => "session_tab_missing",
            .session_layout_missing => "session_layout_missing",
            .replacement_surface_failed => "replacement_surface_failed",
        };
    }

    pub fn message(self: RestoreFailureCode) []const u8 {
        return switch (self) {
            .cwd_missing => "working directory no longer exists",
            .command_missing => "launch command is empty",
            .launch_recipe_invalid => "launch recipe is invalid",
            .session_tab_missing => "saved tab is missing from snapshot",
            .session_layout_missing => "saved session is missing from layout",
            .replacement_surface_failed => "replacement surface could not be realized",
        };
    }
};

pub const RestoreFailure = struct {
    session_id: ids.SessionId,
    code: []const u8,
    message: []const u8,
};

pub fn restoreFailure(
    session_id: ids.SessionId,
    failure_code: RestoreFailureCode,
) RestoreFailure {
    return .{
        .session_id = session_id,
        .code = failure_code.code(),
        .message = failure_code.message(),
    };
}

pub const SelectionFallbackReason = enum {
    selected_window_missing,
    selected_split_missing,
    selected_tab_missing,
    selected_session_missing,

    pub fn code(self: SelectionFallbackReason) []const u8 {
        return switch (self) {
            .selected_window_missing => "selected_window_missing",
            .selected_split_missing => "selected_split_missing",
            .selected_tab_missing => "selected_tab_missing",
            .selected_session_missing => "selected_session_missing",
        };
    }
};

pub const SelectionFallback = struct {
    window_id: ids.WindowId,
    tab_id: ids.TabId,
    session_id: ids.SessionId,
    reason: []const u8,
};

pub fn selectionFallback(
    window_id: ids.WindowId,
    tab_id: ids.TabId,
    session_id: ids.SessionId,
    reason: SelectionFallbackReason,
) SelectionFallback {
    return .{
        .window_id = window_id,
        .tab_id = tab_id,
        .session_id = session_id,
        .reason = reason.code(),
    };
}

pub const RestoreResults = struct {
    restored_workspace_id: ids.WorkspaceId,
    restored_session_ids: []const ids.SessionId = &.{},
    failed_sessions: []const RestoreFailure = &.{},
    selection_fallback: ?SelectionFallback = null,
};

pub const ControlRequest = struct {
    id: ?[]const u8 = null,
    method: []const u8,
    params_json: []const u8 = "{}",
    target: []const u8 = "detect",

    pub fn toJson(self: ControlRequest, alloc: std.mem.Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();
        try std.json.Stringify.value(self, .{}, &out.writer);
        return out.toOwnedSlice();
    }
};

pub const ControlError = struct {
    code: []const u8,
    message: []const u8,
    details_json: ?[]const u8 = null,
};

pub const ControlResponse = struct {
    id: ?[]const u8 = null,
    ok: bool,
    result_json: ?[]const u8 = null,
    @"error": ?ControlError = null,
};

test "workspace validates selected hierarchy" {
    const testing = std.testing;

    const workspace: Workspace = .{
        .workspace_id = ids.WorkspaceId.init(1),
        .name = "dev",
        .slug = "dev",
        .origin = .runtime,
        .selected_window_id = ids.WindowId.init(1),
        .selected_split_id = ids.SplitId.init(1),
        .selected_tab_id = ids.TabId.init(1),
        .selected_session_id = ids.SessionId.init(1),
        .created_at = "2026-03-22T00:00:00Z",
        .updated_at = "2026-03-22T00:00:00Z",
    };
    try workspace.validateSelection();

    const invalid: Workspace = .{
        .workspace_id = ids.WorkspaceId.init(1),
        .name = "dev",
        .slug = "dev",
        .origin = .runtime,
        .selected_split_id = ids.SplitId.init(1),
        .created_at = "2026-03-22T00:00:00Z",
        .updated_at = "2026-03-22T00:00:00Z",
    };
    try testing.expectError(error.SelectedSplitRequiresWindow, invalid.validateSelection());
}
