const std = @import("std");
const gio = @import("gio");
const glib = @import("glib");
const gobject = @import("gobject");
const gtk = @import("gtk");
const internal_os = @import("../../os/main.zig");
const Application = @import("class/application.zig").Application;
const gtk_window = @import("class/window.zig");
const workspace_control_protocol = @import("../workspace_control_protocol.zig");
const workspace_ids = @import("workspace_ids.zig");
const workspace_restore = @import("workspace_restore.zig");
const workspace_snapshot = @import("workspace_snapshot.zig");
const workspace_storage = @import("workspace_storage.zig");

const log = std.log.scoped(.gtk_workspace_control);

pub const action_name = "workspace-control";
pub const initial_response_json =
    \\{"ok":false,"error":{"code":"not_ready","message":"workspace-control has not handled a request yet"}}
;
const action_state_queue_limit = 32;

pub const FocusBehavior = workspace_control_protocol.FocusBehavior;
pub const Method = workspace_control_protocol.Method;

pub const DispatchMetadata = struct {
    method: ?Method = null,
    focus_behavior: FocusBehavior = .no_focus_change,
};

pub const DispatchResult = struct {
    metadata: DispatchMetadata = .{},
    response_json: []u8,
};

fn dispatchMetadata(method: Method) DispatchMetadata {
    return .{
        .method = method,
        .focus_behavior = method.focusBehavior(),
    };
}

fn successResult(
    alloc: std.mem.Allocator,
    id: ?[]const u8,
    method: Method,
    result_json: []const u8,
) !DispatchResult {
    return .{
        .metadata = dispatchMetadata(method),
        .response_json = try encodeSuccessResponseAlloc(alloc, id, result_json),
    };
}

fn errorResult(
    alloc: std.mem.Allocator,
    id: ?[]const u8,
    method: Method,
    code: []const u8,
    message: []const u8,
) !DispatchResult {
    return .{
        .metadata = dispatchMetadata(method),
        .response_json = try encodeErrorResponseAlloc(alloc, id, code, message),
    };
}

const LoadedWorkspaceSnapshot = struct {
    catalog: workspace_snapshot.CatalogEntry,
    snapshot: workspace_snapshot.Snapshot,

    fn deinit(self: *LoadedWorkspaceSnapshot, alloc: std.mem.Allocator) void {
        self.catalog.deinit(alloc);
        self.snapshot.deinit(alloc);
    }
};

pub fn encodeRequestAlloc(
    alloc: std.mem.Allocator,
    id: ?[]const u8,
    method: Method,
    params_json: []const u8,
) ![]u8 {
    return workspace_control_protocol.encodeRequestAlloc(alloc, id, method, params_json);
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
        .workspace_save => dispatchWorkspaceSave(alloc, id, method, params),
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
    const responses = [_][]const u8{initial_response_json};
    return encodeActionStateQueue(&responses) catch unreachable;
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

fn encodeActionStateQueue(responses: []const []const u8) !*glib.Variant {
    const value_z = try encodeActionStateQueueAlloc(std.heap.c_allocator, responses);
    defer std.heap.c_allocator.free(value_z);
    return glib.Variant.newString(value_z);
}

fn encodeActionStateQueueAlloc(
    alloc: std.mem.Allocator,
    responses: []const []const u8,
) ![:0]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    try out.writer.writeAll("{\"responses\":[");
    for (responses, 0..) |response_json, index| {
        try expectJsonObject(response_json);
        if (index != 0) try out.writer.writeByte(',');
        try out.writer.writeAll(response_json);
    }
    try out.writer.writeAll("]}");
    return try out.toOwnedSliceSentinel(0);
}

fn encodeJsonValueAlloc(
    alloc: std.mem.Allocator,
    value: std.json.Value,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try std.json.Stringify.value(value, .{}, &out.writer);
    return out.toOwnedSlice();
}

pub fn decodeActionStateResponsesAlloc(
    alloc: std.mem.Allocator,
    state: ?*glib.Variant,
) ![][]u8 {
    const variant = state orelse return error.InvalidActionState;
    const string_type = glib.VariantType.new("s");
    defer string_type.free();
    if (glib.Variant.isOfType(variant, string_type) == 0) return error.InvalidActionState;

    var len: usize = undefined;
    const value = variant.getString(&len);
    const state_json = value[0..len];

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, state_json, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidActionState;

    if (parsed.value.object.get("responses")) |responses| {
        if (responses != .array) return error.InvalidActionState;

        const items = try alloc.alloc([]u8, responses.array.items.len);
        errdefer alloc.free(items);
        var initialized: usize = 0;
        errdefer {
            for (items[0..initialized]) |item| alloc.free(item);
        }

        for (responses.array.items, 0..) |response_value, index| {
            if (response_value != .object) return error.InvalidActionState;
            items[index] = try encodeJsonValueAlloc(alloc, response_value);
            initialized += 1;
        }
        return items;
    }

    try expectJsonObject(state_json);
    const items = try alloc.alloc([]u8, 1);
    errdefer alloc.free(items);
    items[0] = try alloc.dupe(u8, state_json);
    return items;
}

pub fn decodeActionStateAlloc(
    alloc: std.mem.Allocator,
    state: ?*glib.Variant,
) ![]u8 {
    const responses = try decodeActionStateResponsesAlloc(alloc, state);
    defer {
        for (responses) |response| alloc.free(response);
        alloc.free(responses);
    }
    if (responses.len == 0) return error.InvalidActionState;
    return alloc.dupe(u8, responses[responses.len - 1]);
}

pub fn updateActionStateAlloc(
    alloc: std.mem.Allocator,
    action: *gio.SimpleAction,
    parameter: ?*glib.Variant,
) !DispatchResult {
    const result = try dispatchActionParameterAlloc(alloc, parameter);
    errdefer alloc.free(result.response_json);

    const existing_state = action.as(gio.Action).getState();
    defer if (existing_state) |state| state.unref();

    const existing_responses = try decodeActionStateResponsesAlloc(alloc, existing_state);
    defer {
        for (existing_responses) |response| alloc.free(response);
        alloc.free(existing_responses);
    }

    const preserved_count: usize = @min(existing_responses.len, action_state_queue_limit - 1);
    const start_index = existing_responses.len - preserved_count;
    const next_len = preserved_count + 1;
    const queue = try alloc.alloc([]const u8, next_len);
    defer alloc.free(queue);

    for (0..preserved_count) |index| {
        queue[index] = existing_responses[start_index + index];
    }
    queue[next_len - 1] = result.response_json;

    action.setState(try encodeActionStateQueue(queue));
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

    if (request_id == null) return false;
    if (response_id == null) return false;
    return std.mem.eql(u8, request_id.?, response_id.?);
}

pub fn envelopeIdAlloc(alloc: std.mem.Allocator, json: []const u8) !?[]u8 {
    return parseEnvelopeIdAlloc(alloc, json);
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
    const windows = try workspaceControlWindowsAlloc(alloc);
    defer alloc.free(windows);

    var workspaces: std.ArrayList(gtk_window.WorkspaceControlWorkspace) = .empty;
    defer {
        for (workspaces.items) |workspace| workspace.deinit(alloc);
        workspaces.deinit(alloc);
    }

    for (windows) |window| {
        const window_workspaces = try gtk_window.workspaceControlListAlloc(window, alloc);
        defer alloc.free(window_workspaces);
        try workspaces.appendSlice(alloc, window_workspaces);
    }

    const result_json = try encodeWorkspaceListResultAlloc(alloc, workspaces.items);
    defer alloc.free(result_json);
    return successResult(alloc, id, method, result_json);
}

fn dispatchSessionList(
    alloc: std.mem.Allocator,
    id: ?[]const u8,
    method: Method,
    params: std.json.ObjectMap,
) !DispatchResult {
    const workspace_target = try parseOptionalString(params, "workspace");
    const sessions = sessions: {
        if (workspace_target == null) {
            const window = preferredWorkspaceControlWindow() orelse break :sessions try alloc.alloc(gtk_window.WorkspaceControlSession, 0);
            break :sessions try gtk_window.workspaceControlListSessionsAlloc(window, alloc, null);
        }

        const windows = try workspaceControlWindowsAlloc(alloc);
        defer alloc.free(windows);
        for (windows) |window| {
            const result = gtk_window.workspaceControlListSessionsAlloc(window, alloc, workspace_target) catch |err| switch (err) {
                error.WorkspaceNotFound => continue,
                else => return err,
            };
            break :sessions result;
        }

        return errorResult(alloc, id, method, "not_found", "workspace target could not be resolved");
    };
    defer {
        for (sessions) |session| session.deinit(alloc);
        alloc.free(sessions);
    }

    const result_json = try encodeSessionListResultAlloc(alloc, sessions);
    defer alloc.free(result_json);
    return successResult(alloc, id, method, result_json);
}

fn dispatchWorkspaceOpen(
    alloc: std.mem.Allocator,
    id: ?[]const u8,
    method: Method,
    params: std.json.ObjectMap,
) !DispatchResult {
    const workspace = try requireStringParam(params, "workspace");
    const create = (try parseOptionalBool(params, "create")) orelse false;

    const windows = try workspaceControlWindowsAlloc(alloc);
    defer alloc.free(windows);
    const preferred = preferredWorkspaceControlWindow();

    if (preferred == null) {
        return errorResult(alloc, id, method, "not_ready", "no Ghostty window is available for workspace control");
    }

    const result = result: {
        for (windows) |window| {
            break :result gtk_window.workspaceControlOpen(window, workspace, false) catch |err| switch (err) {
                error.WorkspaceNotFound => continue,
                else => return err,
            };
        }

        if (!create) {
            return errorResult(alloc, id, method, "not_found", "workspace target could not be resolved");
        }

        break :result gtk_window.workspaceControlOpen(preferred.?, workspace, true) catch |err| switch (err) {
            error.WorkspaceNotFound => unreachable,
            else => return err,
        };
    };

    const result_json = try encodeWorkspaceOpenResultAlloc(alloc, result);
    defer alloc.free(result_json);
    return successResult(alloc, id, method, result_json);
}

fn dispatchWorkspaceSave(
    alloc: std.mem.Allocator,
    id: ?[]const u8,
    method: Method,
    params: std.json.ObjectMap,
) !DispatchResult {
    const workspace = try parseOptionalString(params, "workspace");
    const windows = try workspaceControlWindowsAlloc(alloc);
    defer alloc.free(windows);
    if (windows.len == 0) {
        return errorResult(alloc, id, method, "not_ready", "no Ghostty window is available for workspace control");
    }

    const resolved = result: {
        for (windows) |window| {
            if (gtk_window.resolveWorkspaceControlWorkspace(window, workspace)) |candidate| {
                break :result candidate;
            }
        }

        return errorResult(alloc, id, method, "not_found", "workspace target could not be resolved");
    };

    const saved = gtk_window.saveWorkspaceAlloc(resolved.window, alloc, resolved.workspace_page) catch |err| switch (err) {
        error.WorkspaceNotFound => return errorResult(alloc, id, method, "not_found", "workspace target could not be resolved"),
        else => return err,
    };
    defer saved.deinit(alloc);

    const result_json = try encodeWorkspaceSaveResultAlloc(alloc, .{
        .workspace_id = saved.workspace_id,
        .snapshot_id = saved.snapshot_id,
        .saved_at = saved.saved_at,
        .path = saved.path,
    });
    defer alloc.free(result_json);
    return successResult(alloc, id, method, result_json);
}

fn dispatchWorkspaceRestore(
    alloc: std.mem.Allocator,
    id: ?[]const u8,
    method: Method,
    params: std.json.ObjectMap,
) !DispatchResult {
    const workspace = try requireStringParam(params, "workspace");

    var loaded = loadWorkspaceSnapshotForControlAlloc(alloc, workspace) catch |err| switch (err) {
        error.WorkspaceNotFound => return errorResult(alloc, id, method, "not_found", "workspace target could not be resolved"),
        error.NotRestorable => return errorResult(alloc, id, method, "not_restorable", "workspace target has no saved snapshot to restore"),
        error.FileNotFound => return errorResult(alloc, id, method, "not_restorable", "workspace snapshot could not be found on disk"),
        else => return errorResult(alloc, id, method, "restore_invalid", "workspace snapshot is invalid or could not be loaded"),
    };
    defer loaded.deinit(alloc);

    var plan = workspace_restore.planAlloc(alloc, loaded.snapshot) catch {
        return errorResult(alloc, id, method, "restore_invalid", "workspace snapshot is invalid or cannot be planned for restore");
    };
    defer plan.deinit(alloc);

    const window = preferredWorkspaceControlWindow() orelse return errorResult(alloc, id, method, "not_ready", "no Ghostty window is available for workspace restore");

    const results = gtk_window.workspaceControlRestoreAlloc(window, alloc, loaded.snapshot, &plan) catch |err| switch (err) {
        error.TabMultiSessionUnsupported => return errorResult(alloc, id, method, "not_supported", "workspace restore does not yet support multiple sessions inside a single split-local tab"),
        error.WorkspaceSessionEnvUnsupported => return errorResult(alloc, id, method, "not_supported", "workspace restore does not yet support per-session environment overrides"),
        error.WorkspaceLayoutMissing,
        error.WorkspaceLayoutInvalid,
        => return errorResult(alloc, id, method, "restore_invalid", "workspace snapshot is missing a valid top-level layout root"),
        else => return err,
    };
    defer {
        for (results.failed_sessions) |failure| {
            alloc.free(failure.code);
            alloc.free(failure.message);
        }
        alloc.free(results.failed_sessions);
        alloc.free(results.restored_session_ids);
        if (results.selection_fallback) |selection_fallback| alloc.free(selection_fallback.reason);
    }

    const result_json = try encodeWorkspaceRestoreResultAlloc(alloc, results);
    defer alloc.free(result_json);
    return successResult(alloc, id, method, result_json);
}

fn dispatchSessionFocus(
    alloc: std.mem.Allocator,
    id: ?[]const u8,
    method: Method,
    params: std.json.ObjectMap,
) !DispatchResult {
    const session = try requireStringParam(params, "session");
    const windows = try workspaceControlWindowsAlloc(alloc);
    defer alloc.free(windows);
    if (windows.len == 0) {
        return errorResult(alloc, id, method, "not_ready", "no Ghostty window is available for workspace control");
    }

    const result = result: {
        for (windows) |window| {
            break :result gtk_window.workspaceControlFocusSession(window, session) catch |err| switch (err) {
                error.SessionNotFound => continue,
                else => return err,
            };
        }

        return errorResult(alloc, id, method, "not_found", "session target could not be resolved");
    };

    const result_json = try encodeSessionFocusResultAlloc(alloc, result);
    defer alloc.free(result_json);
    return successResult(alloc, id, method, result_json);
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

    const windows = try workspaceControlWindowsAlloc(alloc);
    defer alloc.free(windows);
    if (windows.len == 0) {
        return errorResult(alloc, id, method, "not_ready", "no Ghostty window is available for workspace control");
    }

    const result = result: {
        for (windows) |window| {
            break :result gtk_window.workspaceControlSplitSession(window, .{
                .session = session,
                .direction = parseWorkspaceControlSplitDirection(direction),
                .cwd = cwd,
                .command = command,
            }) catch |err| switch (err) {
                error.SessionNotFound => continue,
                else => return err,
            };
        }

        return errorResult(alloc, id, method, "not_found", "session target could not be resolved");
    };

    const result_json = try encodeSessionSplitResultAlloc(alloc, result);
    defer alloc.free(result_json);
    return successResult(alloc, id, method, result_json);
}

fn dispatchSessionClose(
    alloc: std.mem.Allocator,
    id: ?[]const u8,
    method: Method,
    params: std.json.ObjectMap,
) !DispatchResult {
    const session = try requireStringParam(params, "session");
    const windows = try workspaceControlWindowsAlloc(alloc);
    defer alloc.free(windows);
    if (windows.len == 0) {
        return errorResult(alloc, id, method, "not_ready", "no Ghostty window is available for workspace control");
    }

    const result = result: {
        for (windows) |window| {
            break :result gtk_window.workspaceControlCloseSession(window, session) catch |err| switch (err) {
                error.SessionNotFound => continue,
                else => return err,
            };
        }

        return errorResult(alloc, id, method, "not_found", "session target could not be resolved");
    };

    const result_json = try encodeSessionCloseResultAlloc(alloc, result);
    defer alloc.free(result_json);
    return successResult(alloc, id, method, result_json);
}

fn preferredWorkspaceControlWindow() ?*gtk_window.Window {
    const list = gtk.Window.listToplevels();
    defer list.free();

    var first: ?*gtk_window.Window = null;
    var current: ?*glib.List = list;
    while (current) |node| : (current = node.f_next) {
        const data = node.f_data orelse continue;
        const top_level: *gtk.Window = @ptrCast(@alignCast(data));
        const window = gobject.ext.cast(gtk_window.Window, top_level) orelse continue;
        if (first == null) first = window;
        if (top_level.isActive() != 0) return window;
    }

    return first;
}

fn workspaceControlWindowsAlloc(
    alloc: std.mem.Allocator,
) ![]*gtk_window.Window {
    const list = gtk.Window.listToplevels();
    defer list.free();

    var active: ?*gtk_window.Window = null;
    var others: std.ArrayList(*gtk_window.Window) = .empty;
    defer others.deinit(alloc);

    var current: ?*glib.List = list;
    while (current) |node| : (current = node.f_next) {
        const data = node.f_data orelse continue;
        const top_level: *gtk.Window = @ptrCast(@alignCast(data));
        const window = gobject.ext.cast(gtk_window.Window, top_level) orelse continue;
        if (top_level.isActive() != 0) {
            active = window;
            continue;
        }
        try others.append(alloc, window);
    }

    var windows: std.ArrayList(*gtk_window.Window) = .empty;
    defer windows.deinit(alloc);
    if (active) |window| try windows.append(alloc, window);
    try windows.appendSlice(alloc, others.items);
    return windows.toOwnedSlice(alloc);
}

fn readWorkspaceCatalogAlloc(
    alloc: std.mem.Allocator,
) !workspace_snapshot.Catalog {
    var dir = try workspace_storage.openDefaultStorageDirAlloc(alloc) orelse return .{};
    defer dir.close();
    const storage = workspace_storage.Storage.init(alloc, dir);
    return storage.readCatalogAlloc(alloc, workspace_storage.Storage.catalog_filename) catch |err| switch (err) {
        error.FileNotFound => .{},
        else => return err,
    };
}

fn readWorkspaceSnapshotAlloc(
    alloc: std.mem.Allocator,
    filename: []const u8,
) !workspace_snapshot.Snapshot {
    var dir = try workspace_storage.openDefaultStorageDirAlloc(alloc) orelse return error.FileNotFound;
    defer dir.close();
    const storage = workspace_storage.Storage.init(alloc, dir);
    return storage.readSnapshotAlloc(alloc, filename);
}

fn findCatalogEntryForControlTarget(
    entries: []const workspace_snapshot.CatalogEntry,
    target: []const u8,
) ?workspace_snapshot.CatalogEntry {
    if (parseWorkspaceControlWorkspaceRef(target)) |workspace_id| {
        for (entries) |entry| {
            if (entry.workspace_id == workspace_id) return entry;
        }
    }

    if (workspace_ids.parse(target)) |parsed| {
        if (parsed == .workspace) {
            for (entries) |entry| {
                if (entry.workspace_id == parsed.workspace) return entry;
            }
        }
    } else |_| {}

    for (entries) |entry| {
        const workspace_key = entry.workspace_key orelse continue;
        if (std.mem.eql(u8, workspace_key, target)) return entry;
    }

    for (entries) |entry| {
        if (std.mem.eql(u8, entry.workspace_name, target)) return entry;
    }

    return null;
}

fn workspaceExistsForControlTarget(
    alloc: std.mem.Allocator,
    target: []const u8,
) !bool {
    const windows = try workspaceControlWindowsAlloc(alloc);
    defer alloc.free(windows);

    for (windows) |window| {
        if (gtk_window.resolveWorkspaceControlWorkspace(window, target) != null) return true;
    }

    return false;
}

fn loadWorkspaceSnapshotForControlAlloc(
    alloc: std.mem.Allocator,
    target: []const u8,
) !LoadedWorkspaceSnapshot {
    var catalog = try readWorkspaceCatalogAlloc(alloc);
    defer catalog.deinit(alloc);

    const match = findCatalogEntryForControlTarget(catalog.entries, target);
    if (match) |entry| {
        const catalog_entry = try entry.cloneAlloc(alloc);
        errdefer catalog_entry.deinit(alloc);
        const snapshot_value = try readWorkspaceSnapshotAlloc(alloc, entry.path);
        return .{
            .catalog = catalog_entry,
            .snapshot = snapshot_value,
        };
    }

    if (try workspaceExistsForControlTarget(alloc, target)) {
        return error.NotRestorable;
    }

    return error.WorkspaceNotFound;
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

fn parseWorkspaceControlWorkspaceRef(value: []const u8) ?workspace_ids.WorkspaceId {
    if (std.mem.startsWith(u8, value, "workspace:")) {
        const raw = std.fmt.parseInt(u64, value["workspace:".len..], 10) catch return null;
        if (raw == 0) return null;
        return workspace_ids.WorkspaceId.init(raw);
    }

    const parsed = workspace_ids.parse(value) catch return null;
    return switch (parsed) {
        .workspace => |workspace_id| workspace_id,
        else => null,
    };
}

fn encodeJsonAlloc(
    alloc: std.mem.Allocator,
    value: anytype,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try std.json.Stringify.value(value, .{}, &out.writer);
    return out.toOwnedSlice();
}

fn allocWorkspaceControlShortRef(
    alloc: std.mem.Allocator,
    prefix: []const u8,
    raw: u64,
) ![]u8 {
    return std.fmt.allocPrint(alloc, "{s}:{d}", .{ prefix, raw });
}

fn allocWorkspaceControlCanonicalId(
    alloc: std.mem.Allocator,
    value: anytype,
) ![]u8 {
    var buf: [32]u8 = undefined;
    return alloc.dupe(u8, try value.format(&buf));
}

fn allocOptionalWorkspaceControlCanonicalId(
    alloc: std.mem.Allocator,
    value: anytype,
) !?[]u8 {
    if (value) |id| return try allocWorkspaceControlCanonicalId(alloc, id);
    return null;
}

const WorkspaceListEntryJson = struct {
    id: []const u8,
    workspace_id: []const u8,
    name: []const u8,
    window_id: ?[]const u8,
    selected_session_id: ?[]const u8,
    session_count: usize,
    unread_count: usize,
    has_attention: bool,
    selected: bool,
    restorable: bool,

    fn init(
        alloc: std.mem.Allocator,
        workspace: gtk_window.WorkspaceControlWorkspace,
    ) !WorkspaceListEntryJson {
        return .{
            .id = try allocWorkspaceControlShortRef(alloc, "workspace", workspace.workspace_id.raw()),
            .workspace_id = try allocWorkspaceControlCanonicalId(alloc, workspace.workspace_id),
            .name = workspace.name,
            .window_id = try allocOptionalWorkspaceControlCanonicalId(alloc, workspace.selected_window_id),
            .selected_session_id = try allocOptionalWorkspaceControlCanonicalId(alloc, workspace.selected_session_id),
            .session_count = workspace.session_count,
            .unread_count = workspace.unread_count,
            .has_attention = workspace.has_attention,
            .selected = workspace.selected,
            .restorable = workspace.restorable,
        };
    }

    fn deinit(self: WorkspaceListEntryJson, alloc: std.mem.Allocator) void {
        alloc.free(self.id);
        alloc.free(self.workspace_id);
        if (self.window_id) |window_id| alloc.free(window_id);
        if (self.selected_session_id) |session_id| alloc.free(session_id);
    }
};

const WorkspaceListResultJson = struct {
    workspaces: []const WorkspaceListEntryJson,
};

fn encodeWorkspaceListResultAlloc(
    alloc: std.mem.Allocator,
    workspaces: []const gtk_window.WorkspaceControlWorkspace,
) ![]u8 {
    const entries = try alloc.alloc(WorkspaceListEntryJson, workspaces.len);
    var initialized: usize = 0;
    defer {
        for (entries[0..initialized]) |entry| entry.deinit(alloc);
        alloc.free(entries);
    }

    for (workspaces, 0..) |workspace, index| {
        entries[index] = try WorkspaceListEntryJson.init(alloc, workspace);
        initialized += 1;
    }

    return encodeJsonAlloc(alloc, WorkspaceListResultJson{
        .workspaces = entries,
    });
}

const WorkspaceOpenWorkspaceJson = struct {
    id: []const u8,
    workspace_id: []const u8,
    name: []const u8,
    window_id: ?[]const u8,
    selected_session_id: ?[]const u8,

    fn init(
        alloc: std.mem.Allocator,
        result: gtk_window.WorkspaceControlOpenResult,
    ) !WorkspaceOpenWorkspaceJson {
        return .{
            .id = try allocWorkspaceControlShortRef(alloc, "workspace", result.workspace_id.raw()),
            .workspace_id = try allocWorkspaceControlCanonicalId(alloc, result.workspace_id),
            .name = result.name,
            .window_id = try allocOptionalWorkspaceControlCanonicalId(alloc, result.selected_window_id),
            .selected_session_id = try allocOptionalWorkspaceControlCanonicalId(alloc, result.selected_session_id),
        };
    }

    fn deinit(self: WorkspaceOpenWorkspaceJson, alloc: std.mem.Allocator) void {
        alloc.free(self.id);
        alloc.free(self.workspace_id);
        if (self.window_id) |window_id| alloc.free(window_id);
        if (self.selected_session_id) |session_id| alloc.free(session_id);
    }
};

const WorkspaceOpenResultJson = struct {
    workspace: WorkspaceOpenWorkspaceJson,
};

fn encodeWorkspaceOpenResultAlloc(
    alloc: std.mem.Allocator,
    result: gtk_window.WorkspaceControlOpenResult,
) ![]u8 {
    const workspace = try WorkspaceOpenWorkspaceJson.init(alloc, result);
    defer workspace.deinit(alloc);
    return encodeJsonAlloc(alloc, WorkspaceOpenResultJson{
        .workspace = workspace,
    });
}

const WorkspaceSaveResult = struct {
    workspace_id: workspace_ids.WorkspaceId,
    snapshot_id: workspace_ids.SnapshotId,
    saved_at: []const u8,
    path: []const u8,
};

fn encodeWorkspaceSaveResultAlloc(
    alloc: std.mem.Allocator,
    result: WorkspaceSaveResult,
) ![]u8 {
    const Json = struct {
        const WorkspaceJson = struct {
            id: []const u8,
            workspace_id: []const u8,
            snapshot_id: []const u8,
            saved_at: []const u8,
            path: []const u8,

            fn deinit(self: @This(), alloc_inner: std.mem.Allocator) void {
                alloc_inner.free(self.id);
                alloc_inner.free(self.workspace_id);
                alloc_inner.free(self.snapshot_id);
            }
        };

        workspace: WorkspaceJson,
    };

    const workspace_id_short = try allocWorkspaceControlShortRef(alloc, "workspace", result.workspace_id.raw());
    errdefer alloc.free(workspace_id_short);
    const workspace_id = try allocWorkspaceControlCanonicalId(alloc, result.workspace_id);
    errdefer alloc.free(workspace_id);
    const snapshot_id = try allocWorkspaceControlCanonicalId(alloc, result.snapshot_id);
    errdefer alloc.free(snapshot_id);
    const workspace = Json.WorkspaceJson{
        .id = workspace_id_short,
        .workspace_id = workspace_id,
        .snapshot_id = snapshot_id,
        .saved_at = result.saved_at,
        .path = result.path,
    };
    defer workspace.deinit(alloc);

    return encodeJsonAlloc(alloc, Json{
        .workspace = workspace,
    });
}

fn encodeSessionListResultAlloc(
    alloc: std.mem.Allocator,
    sessions: []const gtk_window.WorkspaceControlSession,
) ![]u8 {
    const SessionListEntryJson = struct {
        id: []const u8,
        session_id: []const u8,
        workspace_id: []const u8,
        tab_id: []const u8,
        title: []const u8,
        cwd: []const u8,
        focused: bool,
        unread: bool,
        has_attention: bool,

        fn init(
            alloc_inner: std.mem.Allocator,
            session: gtk_window.WorkspaceControlSession,
        ) !@This() {
            return .{
                .id = try allocWorkspaceControlShortRef(alloc_inner, "session", session.session_id.raw()),
                .session_id = try allocWorkspaceControlCanonicalId(alloc_inner, session.session_id),
                .workspace_id = try allocWorkspaceControlCanonicalId(alloc_inner, session.workspace_id),
                .tab_id = try allocWorkspaceControlCanonicalId(alloc_inner, session.tab_id),
                .title = session.title,
                .cwd = session.cwd,
                .focused = session.focused,
                .unread = session.unread,
                .has_attention = session.has_attention,
            };
        }

        fn deinit(self: @This(), alloc_inner: std.mem.Allocator) void {
            alloc_inner.free(self.id);
            alloc_inner.free(self.session_id);
            alloc_inner.free(self.workspace_id);
            alloc_inner.free(self.tab_id);
        }
    };
    const SessionListResultJson = struct {
        sessions: []const SessionListEntryJson,
    };

    const entries = try alloc.alloc(SessionListEntryJson, sessions.len);
    var initialized: usize = 0;
    defer {
        for (entries[0..initialized]) |entry| entry.deinit(alloc);
        alloc.free(entries);
    }

    for (sessions, 0..) |session, index| {
        entries[index] = try SessionListEntryJson.init(alloc, session);
        initialized += 1;
    }

    return encodeJsonAlloc(alloc, SessionListResultJson{
        .sessions = entries,
    });
}

fn encodeSessionFocusResultAlloc(
    alloc: std.mem.Allocator,
    result: gtk_window.WorkspaceControlFocusResult,
) ![]u8 {
    const Json = struct {
        focused_session_id: []const u8,
        tab_id: []const u8,
        window_id: []const u8,

        fn deinit(self: @This(), alloc_inner: std.mem.Allocator) void {
            alloc_inner.free(self.focused_session_id);
            alloc_inner.free(self.tab_id);
            alloc_inner.free(self.window_id);
        }
    };

    const focused_session_id = try allocWorkspaceControlCanonicalId(alloc, result.focused_session_id);
    errdefer alloc.free(focused_session_id);
    const tab_id = try allocWorkspaceControlCanonicalId(alloc, result.tab_id);
    errdefer alloc.free(tab_id);
    const window_id = try allocWorkspaceControlCanonicalId(alloc, result.window_id);
    errdefer alloc.free(window_id);
    const json = Json{
        .focused_session_id = focused_session_id,
        .tab_id = tab_id,
        .window_id = window_id,
    };
    defer json.deinit(alloc);

    return encodeJsonAlloc(alloc, json);
}

fn encodeSessionSplitResultAlloc(
    alloc: std.mem.Allocator,
    result: gtk_window.WorkspaceControlSplitResult,
) ![]u8 {
    const Json = struct {
        session_id: []const u8,
        workspace_id: []const u8,
        tab_id: []const u8,

        fn deinit(self: @This(), alloc_inner: std.mem.Allocator) void {
            alloc_inner.free(self.session_id);
            alloc_inner.free(self.workspace_id);
            alloc_inner.free(self.tab_id);
        }
    };

    const session_id = try allocWorkspaceControlCanonicalId(alloc, result.session_id);
    errdefer alloc.free(session_id);
    const workspace_id = try allocWorkspaceControlCanonicalId(alloc, result.workspace_id);
    errdefer alloc.free(workspace_id);
    const tab_id = try allocWorkspaceControlCanonicalId(alloc, result.tab_id);
    errdefer alloc.free(tab_id);
    const json = Json{
        .session_id = session_id,
        .workspace_id = workspace_id,
        .tab_id = tab_id,
    };
    defer json.deinit(alloc);

    return encodeJsonAlloc(alloc, json);
}

fn encodeSessionCloseResultAlloc(
    alloc: std.mem.Allocator,
    result: gtk_window.WorkspaceControlCloseResult,
) ![]u8 {
    const Json = struct {
        closed_session_id: []const u8,

        fn deinit(self: @This(), alloc_inner: std.mem.Allocator) void {
            alloc_inner.free(self.closed_session_id);
        }
    };

    const json = Json{
        .closed_session_id = try allocWorkspaceControlCanonicalId(alloc, result.closed_session_id),
    };
    defer json.deinit(alloc);

    return encodeJsonAlloc(alloc, json);
}

fn encodeWorkspaceRestoreResultAlloc(
    alloc: std.mem.Allocator,
    result: @import("workspace_model.zig").RestoreResults,
) ![]u8 {
    return encodeJsonAlloc(alloc, result);
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
