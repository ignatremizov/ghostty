const std = @import("std");
const gio = @import("gio");
const glib = @import("glib");
const Application = @import("class/application.zig").Application;
const gtk_window = @import("class/window.zig");

const log = std.log.scoped(.gtk_workspace_control);

pub const action_name = "workspace-control";
pub const initial_response_json =
    \\{"ok":false,"error":{"code":"not_ready","message":"workspace-control has not handled a request yet"}}
;

pub const FocusBehavior = enum {
    no_focus_change,
    may_change_focus,
};

pub const Method = enum {
    workspace_list,
    workspace_open,
    workspace_restore,
    session_list,
    session_focus,
    session_split,
    session_close,

    pub fn parse(value: []const u8) ?Method {
        inline for (std.meta.fields(Method)) |field| {
            const method: Method = @enumFromInt(field.value);
            if (std.mem.eql(u8, value, method.name())) return method;
        }
        return null;
    }

    pub fn name(self: Method) []const u8 {
        return switch (self) {
            .workspace_list => "workspace.list",
            .workspace_open => "workspace.open",
            .workspace_restore => "workspace.restore",
            .session_list => "session.list",
            .session_focus => "session.focus",
            .session_split => "session.split",
            .session_close => "session.close",
        };
    }

    pub fn focusBehavior(self: Method) FocusBehavior {
        return switch (self) {
            .workspace_open,
            .session_focus,
            .session_split,
            .session_close,
            => .may_change_focus,
            else => .no_focus_change,
        };
    }
};

pub const DispatchMetadata = struct {
    method: ?Method = null,
    focus_behavior: FocusBehavior = .no_focus_change,
};

pub const DispatchResult = struct {
    metadata: DispatchMetadata = .{},
    response_json: []u8,
};

pub fn encodeRequestAlloc(
    alloc: std.mem.Allocator,
    id: ?[]const u8,
    method: Method,
    params_json: []const u8,
) ![]u8 {
    try expectJsonObject(params_json);

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    try out.writer.writeAll("{");
    if (id) |value| {
        try out.writer.writeAll("\"id\":");
        try std.json.Stringify.value(value, .{}, &out.writer);
        try out.writer.writeAll(",");
    }
    try out.writer.writeAll("\"method\":");
    try std.json.Stringify.value(method.name(), .{}, &out.writer);
    try out.writer.writeAll(",\"params\":");
    try out.writer.writeAll(params_json);
    try out.writer.writeAll("}");

    return out.toOwnedSlice();
}

pub fn dispatchAlloc(
    alloc: std.mem.Allocator,
    request_json: []const u8,
) !DispatchResult {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, request_json, .{}) catch {
        return .{
            .response_json = try encodeErrorResponseAlloc(
                alloc,
                null,
                "invalid_json",
                "request body must be valid JSON",
            ),
        };
    };
    defer parsed.deinit();

    if (parsed.value != .object) {
        return .{
            .response_json = try encodeErrorResponseAlloc(
                alloc,
                null,
                "invalid_request",
                "request envelope must be a JSON object",
            ),
        };
    }

    const object = parsed.value.object;
    const id = parseOptionalId(object) catch {
        return .{
            .response_json = try encodeErrorResponseAlloc(
                alloc,
                null,
                "invalid_request",
                "request id must be a string when provided",
            ),
        };
    };

    const method_name = parseRequiredString(object, "method") catch {
        return .{
            .response_json = try encodeErrorResponseAlloc(
                alloc,
                id,
                "invalid_request",
                "request method must be a string",
            ),
        };
    };

    const method = Method.parse(method_name) orelse {
        return .{
            .response_json = try encodeErrorResponseAlloc(
                alloc,
                id,
                "invalid_method",
                "workspace control method is not supported",
            ),
        };
    };

    const params = parseRequiredObject(object, "params") catch {
        return .{
            .metadata = .{
                .method = method,
                .focus_behavior = method.focusBehavior(),
            },
            .response_json = try encodeErrorResponseAlloc(
                alloc,
                id,
                "invalid_params",
                "request params must be a JSON object",
            ),
        };
    };

    return switch (method) {
        .workspace_list => dispatchWorkspaceList(alloc, id, method),
        .session_list => dispatchSessionList(alloc, id, method, params),
        .workspace_open => dispatchWorkspaceOpen(alloc, id, method, params),
        .workspace_restore => dispatchWorkspaceRestore(alloc, id, method, params),
        .session_focus => dispatchSessionFocus(alloc, id, method, params),
        .session_split => dispatchSessionSplit(alloc, id, method, params),
        .session_close => dispatchSessionClose(alloc, id, method, params),
    } catch |err| switch (err) {
        error.MissingParam,
        error.InvalidParamType,
        error.InvalidParamDirection,
        error.InvalidParamCommand,
        => .{
            .metadata = .{
                .method = method,
                .focus_behavior = method.focusBehavior(),
            },
            .response_json = try encodeErrorResponseAlloc(
                alloc,
                id,
                "invalid_params",
                invalidParamsMessage(err),
            ),
        },
        else => return err,
    };
}

pub fn dispatchActionParameterAlloc(
    alloc: std.mem.Allocator,
    parameter: ?*glib.Variant,
) !DispatchResult {
    const variant = parameter orelse {
        return .{
            .response_json = try encodeErrorResponseAlloc(
                alloc,
                null,
                "invalid_request",
                "workspace-control requires a JSON string request",
            ),
        };
    };

    const string_type = glib.VariantType.new("s");
    defer string_type.free();
    if (glib.Variant.isOfType(variant, string_type) == 0) {
        return .{
            .response_json = try encodeErrorResponseAlloc(
                alloc,
                null,
                "invalid_request",
                "workspace-control request must be encoded as a string parameter",
            ),
        };
    }

    var len: usize = undefined;
    const value = variant.getString(&len);
    return dispatchAlloc(alloc, value[0..len]);
}

pub fn initialStateVariant() *glib.Variant {
    return glib.ext.Variant.newFrom(initial_response_json);
}

pub fn createAction() *gio.SimpleAction {
    const string_type = glib.VariantType.new("s");
    defer string_type.free();

    const action = gio.SimpleAction.newStateful(
        action_name,
        string_type,
        initialStateVariant(),
    );

    _ = gio.SimpleAction.signals.activate.connect(
        action,
        *gio.SimpleAction,
        handleActionActivation,
        action,
        .{},
    );
    return action;
}

pub fn registerAction(map: *gio.ActionMap) void {
    const action = createAction();
    defer action.unref();
    map.addAction(action.as(gio.Action));
}

pub fn unregisterAction(map: *gio.ActionMap) void {
    map.removeAction(action_name);
}

pub fn encodeActionState(response_json: []const u8) !*glib.Variant {
    try expectJsonObject(response_json);
    return glib.ext.Variant.newFrom(response_json);
}

pub fn decodeActionStateAlloc(
    alloc: std.mem.Allocator,
    state: ?*glib.Variant,
) ![]u8 {
    const variant = state orelse return error.InvalidActionState;
    const string_type = glib.VariantType.new("s");
    defer string_type.free();
    if (glib.Variant.isOfType(variant, string_type) == 0) return error.InvalidActionState;

    var len: usize = undefined;
    const value = variant.getString(&len);
    const response_json = value[0..len];
    try expectJsonObject(response_json);
    return alloc.dupe(u8, response_json);
}

pub fn updateActionStateAlloc(
    alloc: std.mem.Allocator,
    action: *gio.SimpleAction,
    parameter: ?*glib.Variant,
) !DispatchResult {
    const result = try dispatchActionParameterAlloc(alloc, parameter);
    errdefer alloc.free(result.response_json);

    action.setState(try encodeActionState(result.response_json));
    return result;
}

pub fn requestIdMatchesResponse(
    alloc: std.mem.Allocator,
    request_json: []const u8,
    response_json: []const u8,
) !bool {
    const request_id = try parseEnvelopeIdAlloc(alloc, request_json);
    defer if (request_id) |id| alloc.free(id);
    const response_id = try parseEnvelopeIdAlloc(alloc, response_json);
    defer if (response_id) |id| alloc.free(id);

    if (request_id == null) return true;
    if (response_id == null) return false;
    return std.mem.eql(u8, request_id.?, response_id.?);
}

pub fn encodeSuccessResponseAlloc(
    alloc: std.mem.Allocator,
    id: ?[]const u8,
    result_json: []const u8,
) ![]u8 {
    try expectJsonValue(result_json);

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    try out.writer.writeAll("{");
    if (id) |value| {
        try out.writer.writeAll("\"id\":");
        try std.json.Stringify.value(value, .{}, &out.writer);
        try out.writer.writeAll(",");
    }
    try out.writer.writeAll("\"ok\":true,\"result\":");
    try out.writer.writeAll(result_json);
    try out.writer.writeAll("}");
    return out.toOwnedSlice();
}

pub fn encodeErrorResponseAlloc(
    alloc: std.mem.Allocator,
    id: ?[]const u8,
    code: []const u8,
    message: []const u8,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    try out.writer.writeAll("{");
    if (id) |value| {
        try out.writer.writeAll("\"id\":");
        try std.json.Stringify.value(value, .{}, &out.writer);
        try out.writer.writeAll(",");
    }
    try out.writer.writeAll("\"ok\":false,\"error\":{\"code\":");
    try std.json.Stringify.value(code, .{}, &out.writer);
    try out.writer.writeAll(",\"message\":");
    try std.json.Stringify.value(message, .{}, &out.writer);
    try out.writer.writeAll("}}");
    return out.toOwnedSlice();
}

fn dispatchWorkspaceList(alloc: std.mem.Allocator, id: ?[]const u8, method: Method) !DispatchResult {
    const workspaces = try gtk_window.workspaceControlListAlloc(alloc);
    defer {
        for (workspaces) |workspace| workspace.deinit(alloc);
        alloc.free(workspaces);
    }

    const result_json = try encodeWorkspaceListResultAlloc(alloc, workspaces);
    defer alloc.free(result_json);
    return .{
        .metadata = .{ .method = method, .focus_behavior = method.focusBehavior() },
        .response_json = try encodeSuccessResponseAlloc(alloc, id, result_json),
    };
}

fn dispatchSessionList(
    alloc: std.mem.Allocator,
    id: ?[]const u8,
    method: Method,
    params: std.json.ObjectMap,
) !DispatchResult {
    const workspace_target = try parseOptionalString(params, "workspace");
    const sessions = gtk_window.workspaceControlListSessionsAlloc(alloc, workspace_target) catch |err| switch (err) {
        error.WorkspaceNotFound => return .{
            .metadata = .{ .method = method, .focus_behavior = method.focusBehavior() },
            .response_json = try encodeErrorResponseAlloc(
                alloc,
                id,
                "not_found",
                "workspace target could not be resolved",
            ),
        },
        else => return err,
    };
    defer {
        for (sessions) |session| session.deinit(alloc);
        alloc.free(sessions);
    }

    const result_json = try encodeSessionListResultAlloc(alloc, sessions);
    defer alloc.free(result_json);
    return .{
        .metadata = .{ .method = method, .focus_behavior = method.focusBehavior() },
        .response_json = try encodeSuccessResponseAlloc(alloc, id, result_json),
    };
}

fn dispatchWorkspaceOpen(
    alloc: std.mem.Allocator,
    id: ?[]const u8,
    method: Method,
    params: std.json.ObjectMap,
) !DispatchResult {
    const workspace = try requireStringParam(params, "workspace");
    const create = (try parseOptionalBool(params, "create")) orelse false;

    const result = gtk_window.workspaceControlOpen(workspace, create) catch |err| switch (err) {
        error.NotReady => return .{
            .metadata = .{ .method = method, .focus_behavior = method.focusBehavior() },
            .response_json = try encodeErrorResponseAlloc(
                alloc,
                id,
                "not_ready",
                "no Ghostty window is available for workspace control",
            ),
        },
        error.WorkspaceNotFound => return .{
            .metadata = .{ .method = method, .focus_behavior = method.focusBehavior() },
            .response_json = try encodeErrorResponseAlloc(
                alloc,
                id,
                "not_found",
                "workspace target could not be resolved",
            ),
        },
        else => return err,
    };

    const result_json = try encodeWorkspaceOpenResultAlloc(alloc, result);
    defer alloc.free(result_json);
    return .{
        .metadata = .{ .method = method, .focus_behavior = method.focusBehavior() },
        .response_json = try encodeSuccessResponseAlloc(alloc, id, result_json),
    };
}

fn dispatchWorkspaceRestore(
    alloc: std.mem.Allocator,
    id: ?[]const u8,
    method: Method,
    params: std.json.ObjectMap,
) !DispatchResult {
    _ = params;
    return .{
        .metadata = .{ .method = method, .focus_behavior = method.focusBehavior() },
        .response_json = try encodeErrorResponseAlloc(
            alloc,
            id,
            "not_supported",
            "workspace.restore is not wired to the live GTK runtime yet",
        ),
    };
}

fn dispatchSessionFocus(
    alloc: std.mem.Allocator,
    id: ?[]const u8,
    method: Method,
    params: std.json.ObjectMap,
) !DispatchResult {
    const session = try requireStringParam(params, "session");
    const result = gtk_window.workspaceControlFocusSession(session) catch |err| switch (err) {
        error.NotReady => return .{
            .metadata = .{ .method = method, .focus_behavior = method.focusBehavior() },
            .response_json = try encodeErrorResponseAlloc(
                alloc,
                id,
                "not_ready",
                "no Ghostty window is available for workspace control",
            ),
        },
        error.SessionNotFound => return .{
            .metadata = .{ .method = method, .focus_behavior = method.focusBehavior() },
            .response_json = try encodeErrorResponseAlloc(
                alloc,
                id,
                "not_found",
                "session target could not be resolved",
            ),
        },
        else => return err,
    };

    const result_json = try encodeSessionFocusResultAlloc(alloc, result);
    defer alloc.free(result_json);
    return .{
        .metadata = .{ .method = method, .focus_behavior = method.focusBehavior() },
        .response_json = try encodeSuccessResponseAlloc(alloc, id, result_json),
    };
}

fn dispatchSessionSplit(
    alloc: std.mem.Allocator,
    id: ?[]const u8,
    method: Method,
    params: std.json.ObjectMap,
) !DispatchResult {
    const session = try requireStringParam(params, "session");
    const direction = try requireSplitDirection(params);
    const cwd = try parseOptionalString(params, "cwd");
    const command = try parseOptionalWorkspaceControlCommandAlloc(alloc, params);
    defer if (command) |owned| deinitWorkspaceControlCommandAlloc(alloc, owned);

    const result = gtk_window.workspaceControlSplitSession(.{
        .session = session,
        .direction = parseWorkspaceControlSplitDirection(direction),
        .cwd = cwd,
        .command = command,
    }) catch |err| switch (err) {
        error.NotReady => return .{
            .metadata = .{ .method = method, .focus_behavior = method.focusBehavior() },
            .response_json = try encodeErrorResponseAlloc(
                alloc,
                id,
                "not_ready",
                "no Ghostty window is available for workspace control",
            ),
        },
        error.SessionNotFound => return .{
            .metadata = .{ .method = method, .focus_behavior = method.focusBehavior() },
            .response_json = try encodeErrorResponseAlloc(
                alloc,
                id,
                "not_found",
                "session target could not be resolved",
            ),
        },
        else => return err,
    };

    const result_json = try encodeSessionSplitResultAlloc(alloc, result);
    defer alloc.free(result_json);
    return .{
        .metadata = .{ .method = method, .focus_behavior = method.focusBehavior() },
        .response_json = try encodeSuccessResponseAlloc(alloc, id, result_json),
    };
}

fn dispatchSessionClose(
    alloc: std.mem.Allocator,
    id: ?[]const u8,
    method: Method,
    params: std.json.ObjectMap,
) !DispatchResult {
    const session = try requireStringParam(params, "session");
    const result = gtk_window.workspaceControlCloseSession(session) catch |err| switch (err) {
        error.NotReady => return .{
            .metadata = .{ .method = method, .focus_behavior = method.focusBehavior() },
            .response_json = try encodeErrorResponseAlloc(
                alloc,
                id,
                "not_ready",
                "no Ghostty window is available for workspace control",
            ),
        },
        error.SessionNotFound => return .{
            .metadata = .{ .method = method, .focus_behavior = method.focusBehavior() },
            .response_json = try encodeErrorResponseAlloc(
                alloc,
                id,
                "not_found",
                "session target could not be resolved",
            ),
        },
        else => return err,
    };

    const result_json = try encodeSessionCloseResultAlloc(alloc, result);
    defer alloc.free(result_json);
    return .{
        .metadata = .{ .method = method, .focus_behavior = method.focusBehavior() },
        .response_json = try encodeSuccessResponseAlloc(alloc, id, result_json),
    };
}

fn handleActionActivation(
    action: *gio.SimpleAction,
    parameter: ?*glib.Variant,
    _: *gio.SimpleAction,
) callconv(.c) void {
    const alloc = Application.default().allocator();
    const result = updateActionStateAlloc(alloc, action, parameter) catch |err| {
        log.warn("workspace-control action dispatch failed err={}", .{err});
        return;
    };
    defer alloc.free(result.response_json);
}

fn invalidParamsMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.MissingParam => "required parameter is missing",
        error.InvalidParamType => "parameter value has the wrong type",
        error.InvalidParamDirection => "split direction must be one of left, right, up, or down",
        error.InvalidParamCommand => "command must be a string or an array of strings",
        else => "invalid params",
    };
}

fn parseOptionalId(object: std.json.ObjectMap) !?[]const u8 {
    const value = object.get("id") orelse return null;
    return switch (value) {
        .null => null,
        .string => value.string,
        else => error.InvalidParamType,
    };
}

fn parseRequiredString(object: std.json.ObjectMap, key: []const u8) ![]const u8 {
    const value = object.get(key) orelse return error.MissingParam;
    return switch (value) {
        .string => value.string,
        else => error.InvalidParamType,
    };
}

fn parseRequiredObject(object: std.json.ObjectMap, key: []const u8) !std.json.ObjectMap {
    const value = object.get(key) orelse return error.MissingParam;
    return switch (value) {
        .object => value.object,
        else => error.InvalidParamType,
    };
}

fn requireStringParam(params: std.json.ObjectMap, key: []const u8) ![]const u8 {
    return parseRequiredString(params, key);
}

fn parseOptionalString(params: std.json.ObjectMap, key: []const u8) !?[]const u8 {
    const value = params.get(key) orelse return null;
    return switch (value) {
        .null => null,
        .string => value.string,
        else => error.InvalidParamType,
    };
}

fn parseOptionalBool(params: std.json.ObjectMap, key: []const u8) !?bool {
    const value = params.get(key) orelse return null;
    return switch (value) {
        .null => null,
        .bool => value.bool,
        else => error.InvalidParamType,
    };
}

fn requireSplitDirection(params: std.json.ObjectMap) ![]const u8 {
    const direction = try requireStringParam(params, "direction");
    if (std.mem.eql(u8, direction, "left") or
        std.mem.eql(u8, direction, "right") or
        std.mem.eql(u8, direction, "up") or
        std.mem.eql(u8, direction, "down"))
    {
        return direction;
    }
    return error.InvalidParamDirection;
}

fn parseOptionalWorkspaceControlCommandAlloc(
    alloc: std.mem.Allocator,
    params: std.json.ObjectMap,
) !?gtk_window.WorkspaceControlCommand {
    const value = params.get("command") orelse return null;
    return switch (value) {
        .null => null,
        .string => .{ .shell = try alloc.dupe(u8, value.string) },
        .array => |items| {
            var argv = std.ArrayList([]const u8).empty;
            errdefer {
                for (argv.items) |item| alloc.free(item);
                argv.deinit(alloc);
            }

            for (items.items) |item| {
                if (item != .string) return error.InvalidParamCommand;
                try argv.append(alloc, try alloc.dupe(u8, item.string));
            }

            return .{ .argv = try argv.toOwnedSlice(alloc) };
        },
        else => error.InvalidParamCommand,
    };
}

fn deinitWorkspaceControlCommandAlloc(
    alloc: std.mem.Allocator,
    command: gtk_window.WorkspaceControlCommand,
) void {
    switch (command) {
        .shell => |value| alloc.free(value),
        .argv => |argv| {
            for (argv) |item| alloc.free(item);
            alloc.free(argv);
        },
    }
}

fn parseWorkspaceControlSplitDirection(
    value: []const u8,
) gtk_window.WorkspaceControlSplitDirection {
    return std.meta.stringToEnum(gtk_window.WorkspaceControlSplitDirection, value) orelse unreachable;
}

fn writeWorkspaceControlShortRef(
    writer: anytype,
    prefix: []const u8,
    raw: u64,
) !void {
    try writer.print("{s}:{d}", .{ prefix, raw });
}

fn writeWorkspaceControlCanonicalId(
    writer: anytype,
    value: anytype,
) !void {
    var buf: [32]u8 = undefined;
    try writer.writeAll(try value.format(&buf));
}

fn encodeWorkspaceListResultAlloc(
    alloc: std.mem.Allocator,
    workspaces: []const gtk_window.WorkspaceControlWorkspace,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    try out.writer.writeAll("{\"workspaces\":[");
    for (workspaces, 0..) |workspace, index| {
        if (index != 0) try out.writer.writeByte(',');
        try out.writer.writeAll("{\"id\":\"");
        try writeWorkspaceControlShortRef(&out.writer, "workspace", workspace.workspace_id.raw());
        try out.writer.writeAll("\",\"workspace_id\":\"");
        try writeWorkspaceControlCanonicalId(&out.writer, workspace.workspace_id);
        try out.writer.writeAll("\",\"name\":");
        try std.json.Stringify.value(workspace.name, .{}, &out.writer);
        try out.writer.writeAll(",\"window_id\":");
        if (workspace.selected_window_id) |window_id| {
            try out.writer.writeByte('"');
            try writeWorkspaceControlCanonicalId(&out.writer, window_id);
            try out.writer.writeByte('"');
        } else {
            try out.writer.writeAll("null");
        }
        try out.writer.writeAll(",\"selected_session_id\":");
        if (workspace.selected_session_id) |session_id| {
            try out.writer.writeByte('"');
            try writeWorkspaceControlCanonicalId(&out.writer, session_id);
            try out.writer.writeByte('"');
        } else {
            try out.writer.writeAll("null");
        }
        try out.writer.print(",\"session_count\":{d},\"unread_count\":{d},\"has_attention\":{},\"selected\":{},\"restorable\":{}", .{
            workspace.session_count,
            workspace.unread_count,
            workspace.has_attention,
            workspace.selected,
            workspace.restorable,
        });
        try out.writer.writeAll("}");
    }
    try out.writer.writeAll("]}");
    return out.toOwnedSlice();
}

fn encodeWorkspaceOpenResultAlloc(
    alloc: std.mem.Allocator,
    result: gtk_window.WorkspaceControlOpenResult,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    try out.writer.writeAll("{\"workspace\":{\"id\":\"");
    try writeWorkspaceControlShortRef(&out.writer, "workspace", result.workspace_id.raw());
    try out.writer.writeAll("\",\"workspace_id\":\"");
    try writeWorkspaceControlCanonicalId(&out.writer, result.workspace_id);
    try out.writer.writeAll("\",\"name\":");
    try std.json.Stringify.value(result.name, .{}, &out.writer);
    try out.writer.writeAll(",\"window_id\":");
    if (result.selected_window_id) |window_id| {
        try out.writer.writeByte('"');
        try writeWorkspaceControlCanonicalId(&out.writer, window_id);
        try out.writer.writeByte('"');
    } else {
        try out.writer.writeAll("null");
    }
    try out.writer.writeAll(",\"selected_session_id\":");
    if (result.selected_session_id) |session_id| {
        try out.writer.writeByte('"');
        try writeWorkspaceControlCanonicalId(&out.writer, session_id);
        try out.writer.writeByte('"');
    } else {
        try out.writer.writeAll("null");
    }
    try out.writer.writeAll("}}");
    return out.toOwnedSlice();
}

fn encodeSessionListResultAlloc(
    alloc: std.mem.Allocator,
    sessions: []const gtk_window.WorkspaceControlSession,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    try out.writer.writeAll("{\"sessions\":[");
    for (sessions, 0..) |session, index| {
        if (index != 0) try out.writer.writeByte(',');
        try out.writer.writeAll("{\"id\":\"");
        try writeWorkspaceControlShortRef(&out.writer, "session", session.session_id.raw());
        try out.writer.writeAll("\",\"session_id\":\"");
        try writeWorkspaceControlCanonicalId(&out.writer, session.session_id);
        try out.writer.writeAll("\",\"workspace_id\":\"");
        try writeWorkspaceControlCanonicalId(&out.writer, session.workspace_id);
        try out.writer.writeAll("\",\"tab_id\":\"");
        try writeWorkspaceControlCanonicalId(&out.writer, session.tab_id);
        try out.writer.writeAll("\",\"title\":");
        try std.json.Stringify.value(session.title, .{}, &out.writer);
        try out.writer.writeAll(",\"cwd\":");
        try std.json.Stringify.value(session.cwd, .{}, &out.writer);
        try out.writer.print(",\"focused\":{},\"unread\":{},\"has_attention\":{}", .{
            session.focused,
            session.unread,
            session.has_attention,
        });
        try out.writer.writeAll("}");
    }
    try out.writer.writeAll("]}");
    return out.toOwnedSlice();
}

fn encodeSessionFocusResultAlloc(
    alloc: std.mem.Allocator,
    result: gtk_window.WorkspaceControlFocusResult,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    try out.writer.writeAll("{\"focused_session_id\":\"");
    try writeWorkspaceControlCanonicalId(&out.writer, result.focused_session_id);
    try out.writer.writeAll("\",\"tab_id\":\"");
    try writeWorkspaceControlCanonicalId(&out.writer, result.tab_id);
    try out.writer.writeAll("\",\"window_id\":\"");
    try writeWorkspaceControlCanonicalId(&out.writer, result.window_id);
    try out.writer.writeAll("\"}");
    return out.toOwnedSlice();
}

fn encodeSessionSplitResultAlloc(
    alloc: std.mem.Allocator,
    result: gtk_window.WorkspaceControlSplitResult,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    try out.writer.writeAll("{\"session_id\":\"");
    try writeWorkspaceControlCanonicalId(&out.writer, result.session_id);
    try out.writer.writeAll("\",\"workspace_id\":\"");
    try writeWorkspaceControlCanonicalId(&out.writer, result.workspace_id);
    try out.writer.writeAll("\",\"tab_id\":\"");
    try writeWorkspaceControlCanonicalId(&out.writer, result.tab_id);
    try out.writer.writeAll("\"}");
    return out.toOwnedSlice();
}

fn encodeSessionCloseResultAlloc(
    alloc: std.mem.Allocator,
    result: gtk_window.WorkspaceControlCloseResult,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    try out.writer.writeAll("{\"closed_session_id\":\"");
    try writeWorkspaceControlCanonicalId(&out.writer, result.closed_session_id);
    try out.writer.writeAll("\"}");
    return out.toOwnedSlice();
}

fn parseEnvelopeIdAlloc(alloc: std.mem.Allocator, json: []const u8) !?[]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, json, .{});
    defer parsed.deinit();

    if (parsed.value != .object) return error.InvalidEnvelope;
    const value = parsed.value.object.get("id") orelse return null;
    return switch (value) {
        .null => null,
        .string => try alloc.dupe(u8, value.string),
        else => error.InvalidEnvelope,
    };
}

fn expectJsonObject(json: []const u8) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, std.heap.smp_allocator, json, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidFormat;
}

fn expectJsonValue(json: []const u8) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, std.heap.smp_allocator, json, .{});
    defer parsed.deinit();
}

test {
    _ = @import("workspace_control_test.zig");
}
