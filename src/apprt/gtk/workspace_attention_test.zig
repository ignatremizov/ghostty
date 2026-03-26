const std = @import("std");
const attention = @import("workspace_attention.zig");
const ids = @import("workspace_ids.zig");

fn sessionState(raw_id: u64) attention.AttentionState {
    return attention.AttentionState.initSession(ids.SessionId.init(raw_id));
}

test "workspace attention marks background output as unread and aggregates sessions" {
    const testing = std.testing;

    var state = sessionState(1);
    try testing.expect(!state.hasAttention());

    try testing.expect(state.observeOutput(.{
        .event_at = "2026-03-22T10:00:00Z",
        .is_focused = false,
    }));

    try testing.expect(state.unread);
    try testing.expect(!state.bell);
    try testing.expectEqual(attention.Source.output, state.source);
    try testing.expectEqualStrings("2026-03-22T10:00:00Z", state.last_event_at.?);
    try testing.expect(state.cleared_at == null);

    const summary = attention.AttentionSummary.summarizeSessions(&.{state});
    try testing.expectEqual(@as(usize, 1), summary.unread_count);
    try testing.expectEqual(@as(usize, 0), summary.bell_count);
    try testing.expect(summary.needs_attention);
}

test "workspace attention bell events preserve unread and bell summary" {
    const testing = std.testing;

    var state = sessionState(2);
    _ = state.observeOutput(.{
        .event_at = "2026-03-22T10:01:00Z",
        .is_focused = false,
    });

    try testing.expect(state.observeBell(.{
        .event_at = "2026-03-22T10:02:00Z",
        .is_focused = false,
    }));

    try testing.expect(state.unread);
    try testing.expect(state.bell);
    try testing.expectEqual(attention.Source.bell, state.source);
    try testing.expectEqualStrings("2026-03-22T10:02:00Z", state.last_event_at.?);

    var other = sessionState(3);
    _ = other.observeOutput(.{
        .event_at = "2026-03-22T10:03:00Z",
        .is_focused = false,
    });
    const workspace_state: attention.AttentionState = .{
        .target_id = .{ .workspace = ids.WorkspaceId.init(1) },
        .unread = true,
        .last_event_at = "2026-03-22T10:04:00Z",
        .source = .manual,
    };

    const summary = attention.AttentionSummary.summarizeSessions(&.{ state, other, workspace_state });
    try testing.expectEqual(@as(usize, 2), summary.unread_count);
    try testing.expectEqual(@as(usize, 1), summary.bell_count);
    try testing.expect(summary.needs_attention);
}

test "workspace attention focus clear removes unread and suppresses focused output" {
    const testing = std.testing;

    var state = sessionState(4);
    _ = state.observeOutput(.{
        .event_at = "2026-03-22T10:05:00Z",
        .is_focused = false,
    });

    try testing.expect(state.clearForFocus("2026-03-22T10:06:00Z"));
    try testing.expect(!state.hasAttention());
    try testing.expectEqualStrings("2026-03-22T10:06:00Z", state.cleared_at.?);

    try testing.expect(!state.observeOutput(.{
        .event_at = "2026-03-22T10:07:00Z",
        .is_focused = true,
    }));

    try testing.expect(!state.hasAttention());
    try testing.expectEqualStrings("2026-03-22T10:05:00Z", state.last_event_at.?);
}

test "workspace attention acknowledge clear removes bell state" {
    const testing = std.testing;

    var state = sessionState(5);
    _ = state.observeBell(.{
        .event_at = "2026-03-22T10:08:00Z",
        .is_focused = false,
    });

    try testing.expect(state.clearForAcknowledge("2026-03-22T10:09:00Z"));
    try testing.expect(!state.unread);
    try testing.expect(!state.bell);
    try testing.expectEqualStrings("2026-03-22T10:09:00Z", state.cleared_at.?);
    try testing.expect(!state.clearForAcknowledge("2026-03-22T10:10:00Z"));
}

test "workspace attention preserves focused bell events until acknowledged" {
    const testing = std.testing;

    var state = sessionState(8);
    try testing.expect(state.observeBell(.{
        .event_at = "2026-03-22T10:10:30Z",
        .is_focused = true,
    }));
    try testing.expect(state.hasAttention());
    try testing.expect(state.unread);
    try testing.expect(state.bell);
    try testing.expectEqual(attention.Source.bell, state.source);
    try testing.expectEqualStrings("2026-03-22T10:10:30Z", state.last_event_at.?);
    try testing.expect(state.clearForAcknowledge("2026-03-22T10:10:31Z"));
    try testing.expect(!state.hasAttention());
}

test "workspace attention session close clear drops pending state from workspace summary" {
    const testing = std.testing;

    var closing = sessionState(6);
    _ = closing.observeBell(.{
        .event_at = "2026-03-22T10:11:00Z",
        .is_focused = false,
    });

    var still_pending = sessionState(7);
    _ = still_pending.observeOutput(.{
        .event_at = "2026-03-22T10:12:00Z",
        .is_focused = false,
    });

    try testing.expect(closing.clearForSessionClose("2026-03-22T10:13:00Z"));

    const summary = attention.AttentionSummary.summarizeSessions(&.{ closing, still_pending });
    try testing.expectEqual(@as(usize, 1), summary.unread_count);
    try testing.expectEqual(@as(usize, 0), summary.bell_count);
    try testing.expect(summary.needs_attention);
    try testing.expectEqualStrings("2026-03-22T10:13:00Z", closing.cleared_at.?);
}
