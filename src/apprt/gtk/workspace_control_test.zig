const std = @import("std");
const gio = @import("gio");
const glib = @import("glib");

const workspace_control = @import("workspace_control.zig");

fn stringVariant(value: []const u8) *glib.Variant {
    return glib.ext.Variant.newFrom(value);
}

test "ipc workspace control encodes stable request envelope" {
    const testing = std.testing;

    const encoded = try workspace_control.encodeRequestAlloc(
        testing.allocator,
        "req-1",
        .workspace_list,
        "{}",
    );
    defer testing.allocator.free(encoded);

    try testing.expect(std.mem.indexOf(u8, encoded, "\"id\":\"req-1\"") != null);
    try testing.expect(std.mem.indexOf(u8, encoded, "\"method\":\"workspace.list\"") != null);
    try testing.expect(std.mem.indexOf(u8, encoded, "\"params\":{}") != null);
}

test "ipc workspace control returns workspace list response" {
    const testing = std.testing;

    const request = try workspace_control.encodeRequestAlloc(
        testing.allocator,
        "req-2",
        .workspace_list,
        "{}",
    );
    defer testing.allocator.free(request);

    const result = try workspace_control.dispatchAlloc(testing.allocator, request);
    defer testing.allocator.free(result.response_json);

    try testing.expectEqual(workspace_control.Method.workspace_list, result.metadata.method.?);
    try testing.expectEqual(workspace_control.FocusBehavior.no_focus_change, result.metadata.focus_behavior);
    try testing.expect(std.mem.indexOf(u8, result.response_json, "\"ok\":true") != null);
    try testing.expect(std.mem.indexOf(u8, result.response_json, "\"workspaces\":[]") != null);
}

test "ipc workspace control rejects unsupported methods with request id" {
    const testing = std.testing;

    const result = try workspace_control.dispatchAlloc(
        testing.allocator,
        "{\"id\":\"req-3\",\"method\":\"workspace.delete\",\"params\":{}}",
    );
    defer testing.allocator.free(result.response_json);

    try testing.expectEqual(@as(?workspace_control.Method, null), result.metadata.method);
    try testing.expect(std.mem.indexOf(u8, result.response_json, "\"id\":\"req-3\"") != null);
    try testing.expect(std.mem.indexOf(u8, result.response_json, "\"code\":\"invalid_method\"") != null);
}

test "ipc workspace control validates session split params before dispatch" {
    const testing = std.testing;

    const invalid_direction = try workspace_control.dispatchAlloc(
        testing.allocator,
        "{\"id\":\"req-4\",\"method\":\"session.split\",\"params\":{\"session\":\"session:2\",\"direction\":\"sideways\"}}",
    );
    defer testing.allocator.free(invalid_direction.response_json);

    try testing.expectEqual(workspace_control.Method.session_split, invalid_direction.metadata.method.?);
    try testing.expectEqual(workspace_control.FocusBehavior.no_focus_change, invalid_direction.metadata.focus_behavior);
    try testing.expect(std.mem.indexOf(u8, invalid_direction.response_json, "\"code\":\"invalid_params\"") != null);
}

test "ipc workspace control marks mutating workspace actions as focus-changing" {
    const testing = std.testing;

    try testing.expectEqual(workspace_control.FocusBehavior.may_change_focus, workspace_control.Method.workspace_open.focusBehavior());
    try testing.expectEqual(workspace_control.FocusBehavior.no_focus_change, workspace_control.Method.workspace_restore.focusBehavior());
    try testing.expectEqual(workspace_control.FocusBehavior.may_change_focus, workspace_control.Method.session_split.focusBehavior());
    try testing.expectEqual(workspace_control.FocusBehavior.may_change_focus, workspace_control.Method.session_close.focusBehavior());
    try testing.expectEqual(workspace_control.FocusBehavior.may_change_focus, workspace_control.Method.session_focus.focusBehavior());
}

test "ipc workspace control action parameter decodes variant strings" {
    const testing = std.testing;

    const request = try workspace_control.encodeRequestAlloc(
        testing.allocator,
        null,
        .session_list,
        "{\"workspace\":\"workspace:1\"}",
    );
    defer testing.allocator.free(request);

    const variant = stringVariant(request);
    defer variant.unref();

    const result = try workspace_control.dispatchActionParameterAlloc(testing.allocator, variant);
    defer testing.allocator.free(result.response_json);

    try testing.expectEqual(workspace_control.Method.session_list, result.metadata.method.?);
    try testing.expect(std.mem.indexOf(u8, result.response_json, "\"sessions\":[]") != null);
}

test "ipc workspace control updates action state with caller-visible JSON" {
    const testing = std.testing;

    const request = try workspace_control.encodeRequestAlloc(
        testing.allocator,
        "req-5",
        .workspace_list,
        "{}",
    );
    defer testing.allocator.free(request);

    const action = workspace_control.createAction();
    defer action.unref();

    const parameter = stringVariant(request);
    defer parameter.unref();

    const result = try workspace_control.updateActionStateAlloc(
        testing.allocator,
        action,
        parameter,
    );
    defer testing.allocator.free(result.response_json);

    const state = action.as(gio.Action).getState().?;
    defer state.unref();

    const decoded = try workspace_control.decodeActionStateAlloc(testing.allocator, state);
    defer testing.allocator.free(decoded);

    try testing.expectEqual(workspace_control.Method.workspace_list, result.metadata.method.?);
    try testing.expectEqualStrings(result.response_json, decoded);
}
