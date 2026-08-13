const std = @import("std");
const ids = @import("workspace_ids.zig");

pub const TargetKind = enum {
    workspace,
    tab,
    session,
};

pub const Source = enum {
    output,
    bell,
    manual,
};

pub const EventContext = struct {
    event_at: ?[]const u8 = null,
    is_focused: bool = false,
};

pub const AttentionSummary = struct {
    unread_count: usize = 0,
    bell_count: usize = 0,
    needs_attention: bool = false,

    pub fn include(self: *AttentionSummary, state: AttentionState) void {
        if (state.unread) self.unread_count += 1;
        if (state.bell) self.bell_count += 1;
        self.needs_attention = self.needs_attention or state.hasAttention();
    }

    pub fn merge(self: *AttentionSummary, other: AttentionSummary) void {
        self.unread_count += other.unread_count;
        self.bell_count += other.bell_count;
        self.needs_attention = self.needs_attention or other.needs_attention;
    }

    pub fn summarize(states: []const AttentionState) AttentionSummary {
        var summary: AttentionSummary = .{};
        for (states) |state| summary.include(state);
        return summary;
    }

    pub fn summarizeTarget(
        states: []const AttentionState,
        target_kind: TargetKind,
    ) AttentionSummary {
        var summary: AttentionSummary = .{};
        for (states) |state| {
            if (state.targetKind() != target_kind) continue;
            summary.include(state);
        }
        return summary;
    }

    pub fn summarizeSessions(states: []const AttentionState) AttentionSummary {
        return summarizeTarget(states, .session);
    }
};

pub const TargetId = union(TargetKind) {
    workspace: ids.WorkspaceId,
    tab: ids.TabId,
    session: ids.SessionId,

    pub fn jsonStringify(self: TargetId, writer: anytype) !void {
        switch (self) {
            inline else => |value| try writer.write(value),
        }
    }
};

pub const AttentionState = struct {
    target_id: TargetId,
    unread: bool = false,
    bell: bool = false,
    last_event_at: ?[]const u8 = null,
    source: Source = .manual,
    cleared_at: ?[]const u8 = null,

    pub fn initSession(session_id: ids.SessionId) AttentionState {
        return .{ .target_id = .{ .session = session_id } };
    }

    pub fn targetKind(self: AttentionState) TargetKind {
        return std.meta.activeTag(self.target_id);
    }

    pub fn hasAttention(self: AttentionState) bool {
        return self.unread or self.bell;
    }

    pub fn clear(self: *AttentionState, cleared_at: ?[]const u8) bool {
        if (!self.hasAttention()) return false;

        self.unread = false;
        self.bell = false;
        self.cleared_at = cleared_at;
        return true;
    }

    pub fn clearForFocus(self: *AttentionState, cleared_at: ?[]const u8) bool {
        return self.clear(cleared_at);
    }

    pub fn clearForAcknowledge(self: *AttentionState, cleared_at: ?[]const u8) bool {
        return self.clear(cleared_at);
    }

    pub fn clearForSessionClose(self: *AttentionState, cleared_at: ?[]const u8) bool {
        return self.clear(cleared_at);
    }

    pub fn markOutput(self: *AttentionState, event_at: ?[]const u8) void {
        self.unread = true;
        self.last_event_at = event_at;
        self.source = .output;
        self.cleared_at = null;
    }

    pub fn markBell(self: *AttentionState, event_at: ?[]const u8) void {
        self.unread = true;
        self.bell = true;
        self.last_event_at = event_at;
        self.source = .bell;
        self.cleared_at = null;
    }

    pub fn observeOutput(self: *AttentionState, context: EventContext) bool {
        if (context.is_focused) return false;

        self.markOutput(context.event_at);
        return true;
    }

    pub fn observeBell(self: *AttentionState, context: EventContext) bool {
        self.markBell(context.event_at);
        return true;
    }
};

test {
    _ = @import("workspace_attention_test.zig");
}
