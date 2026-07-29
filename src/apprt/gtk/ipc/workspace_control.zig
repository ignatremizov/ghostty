const std = @import("std");
const Allocator = std.mem.Allocator;
const gio = @import("gio");
const glib = @import("glib");

const apprt = @import("../../../apprt.zig");
const global = @import("../../../global.zig");
const DBus = @import("DBus.zig");
const workspace_control = @import("../workspace_control.zig");

const stderr_buffer_size = 4096;
const response_timeout: std.Io.Duration = .fromSeconds(5);
const save_response_timeout: std.Io.Duration = .fromSeconds(60);
const poll_interval: std.Io.Duration = .fromMilliseconds(10);
const timeout_message = "Timed out waiting for workspace-control response from Ghostty\n";

const ResponseWaitError = error{
    ResponseTimeout,
};

fn freeResponses(alloc: Allocator, responses: [][]u8) void {
    for (responses) |response_json| alloc.free(response_json);
    alloc.free(responses);
}

fn actionStateResponsesAlloc(
    alloc: Allocator,
    action_group: *gio.ActionGroup,
) Allocator.Error![][]u8 {
    const state = action_group.getActionState(workspace_control.action_name) orelse {
        return try alloc.alloc([]u8, 0);
    };
    defer state.unref();

    return workspace_control.decodeActionStateResponsesAlloc(alloc, state) catch {
        return try alloc.alloc([]u8, 0);
    };
}

fn responseQueueChanged(previous: []const []const u8, current: []const []const u8) bool {
    if (previous.len != current.len) return true;
    for (previous, current) |lhs, rhs| {
        if (!std.mem.eql(u8, lhs, rhs)) return true;
    }
    return false;
}
fn freshResponseStartIndex(previous: []const []const u8, current: []const []const u8) usize {
    const max_overlap = @min(previous.len, current.len);
    var overlap = max_overlap;
    while (overlap > 0) : (overlap -= 1) {
        const previous_tail = previous[previous.len - overlap ..];
        const current_head = current[0..overlap];
        var matches = true;
        for (previous_tail, current_head) |lhs, rhs| {
            if (!std.mem.eql(u8, lhs, rhs)) {
                matches = false;
                break;
            }
        }
        if (matches) return overlap;
    }
    return 0;
}

fn waitForMatchingResponse(
    alloc: Allocator,
    ctx: *glib.MainContext,
    action_group: *gio.ActionGroup,
    initial_responses: []const []const u8,
    request_json: []const u8,
) (Allocator.Error || ResponseWaitError)![]u8 {
    const request_id = workspace_control.envelopeIdAlloc(alloc, request_json) catch null;
    defer if (request_id) |id| alloc.free(id);

    const method = workspace_control.requestMethod(alloc, request_json) catch null;
    const timeout = if (method == .workspace_save)
        save_response_timeout
    else
        response_timeout;
    const deadline = std.Io.Timestamp.now(global.io(), .awake).addDuration(timeout);
    while (std.Io.Timestamp.now(global.io(), .awake).nanoseconds < deadline.nanoseconds) {
        while (glib.MainContext.pending(ctx) != 0) {
            _ = glib.MainContext.iteration(ctx, 0);
        }

        const state = action_group.getActionState(workspace_control.action_name) orelse {
            std.Io.sleep(global.io(), poll_interval, .awake) catch {};
            continue;
        };
        defer state.unref();

        const responses = workspace_control.decodeActionStateResponsesAlloc(alloc, state) catch {
            std.Io.sleep(global.io(), poll_interval, .awake) catch {};
            continue;
        };
        defer freeResponses(alloc, responses);

        if (request_id == null) {
            if (responses.len > 0 and responseQueueChanged(initial_responses, responses)) {
                return try alloc.dupe(u8, responses[responses.len - 1]);
            }
            std.Io.sleep(global.io(), poll_interval, .awake) catch {};
            continue;
        }

        const fresh_start = freshResponseStartIndex(initial_responses, responses);
        const fresh_responses = responses[fresh_start..];

        for (fresh_responses) |response_json| {
            const matches = workspace_control.requestIdMatchesResponse(
                alloc,
                request_json,
                response_json,
            ) catch continue;
            if (!matches) continue;
            return try alloc.dupe(u8, response_json);
        }

        std.Io.sleep(global.io(), poll_interval, .awake) catch {};
    }

    return error.ResponseTimeout;
}

pub fn workspaceControl(
    alloc: Allocator,
    target: apprt.ipc.Target,
    request_json: []const u8,
) (Allocator.Error || std.Io.Writer.Error || apprt.ipc.Errors)![]u8 {
    var buf: [stderr_buffer_size]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(global.io(), &buf);
    const stderr = &stderr_writer.interface;

    var dbus = try DBus.init(alloc, target, workspace_control.action_name);
    defer dbus.deinit(alloc);

    const group = gio.DBusActionGroup.get(
        dbus.dbus,
        dbus.bus_name,
        dbus.object_path,
    );
    defer group.unref();

    const action_group = group.as(gio.ActionGroup);

    const initial_responses = try actionStateResponsesAlloc(alloc, action_group);
    defer freeResponses(alloc, initial_responses);

    const request_json_z = try alloc.dupeZ(u8, request_json);
    defer alloc.free(request_json_z);
    const parameter = glib.Variant.newString(request_json_z);
    dbus.addParameter(parameter);
    try dbus.send();

    const ctx = glib.MainContext.default();
    return waitForMatchingResponse(alloc, ctx, action_group, initial_responses, request_json) catch |err| switch (err) {
        error.ResponseTimeout => {
            try stderr.writeAll(timeout_message);
            try stderr.flush();
            return error.IPCFailed;
        },
        else => |other| return other,
    };
}

test "workspace control response queue changed detects fresh id-less replies" {
    const testing = std.testing;

    const previous = [_][]const u8{workspace_control.initial_response_json};
    const same = [_][]const u8{workspace_control.initial_response_json};
    const grown = [_][]const u8{
        workspace_control.initial_response_json,
        "{\"ok\":true}",
    };
    const replaced = [_][]const u8{"{\"ok\":true}"};

    try testing.expect(!responseQueueChanged(&previous, &same));
    try testing.expect(responseQueueChanged(&previous, &grown));
    try testing.expect(responseQueueChanged(&previous, &replaced));
}

test "workspace control repeated ids ignore stale queued responses" {
    const testing = std.testing;

    const previous = [_][]const u8{
        "{\"id\":\"same\",\"ok\":false}",
    };
    const current = [_][]const u8{
        "{\"id\":\"same\",\"ok\":false}",
        "{\"id\":\"same\",\"ok\":true}",
    };
    const fresh = if (current.len > previous.len) current[previous.len..] else &.{};

    try testing.expectEqual(@as(usize, 1), fresh.len);
    try testing.expect(std.mem.indexOf(u8, fresh[0], "\"ok\":true") != null);
}
