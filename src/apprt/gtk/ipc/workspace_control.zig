const std = @import("std");
const Allocator = std.mem.Allocator;
const gio = @import("gio");
const glib = @import("glib");

const apprt = @import("../../../apprt.zig");
const DBus = @import("DBus.zig");
const workspace_control = @import("../workspace_control.zig");

pub fn workspaceControl(
    alloc: Allocator,
    target: apprt.ipc.Target,
    request_json: []const u8,
) (Allocator.Error || std.Io.Writer.Error || apprt.ipc.Errors)![]u8 {
    var buf: [256]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&buf);
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
    if (action_group.hasAction(workspace_control.action_name) == 0) {
        try stderr.print(
            "workspace-control action is not exported by the running Ghostty instance\n",
            .{},
        );
        try stderr.flush();
        return error.IPCFailed;
    }

    const parameter = glib.ext.Variant.newFrom(request_json);
    defer parameter.unref();
    action_group.activateAction(workspace_control.action_name, parameter);

    {
        var err_: ?*glib.Error = null;
        defer if (err_) |err| err.free();
        if (dbus.dbus.flushSync(null, &err_) == 0) {
            try stderr.print(
                "Unable to flush workspace-control action to D-Bus: {s}\n",
                .{if (err_) |err| err.f_message orelse "(unknown)" else "(unknown)"},
            );
            try stderr.flush();
            return error.IPCFailed;
        }
    }

    const ctx = glib.MainContext.default();
    for (0..50) |_| {
        while (glib.MainContext.pending(ctx) != 0) {
            _ = glib.MainContext.iteration(ctx, 0);
        }

        const state = action_group.getActionState(workspace_control.action_name) orelse {
            std.Thread.sleep(10 * std.time.ns_per_ms);
            continue;
        };
        defer state.unref();

        const response_json = workspace_control.decodeActionStateAlloc(alloc, state) catch {
            std.Thread.sleep(10 * std.time.ns_per_ms);
            continue;
        };
        errdefer alloc.free(response_json);

        const matches = workspace_control.requestIdMatchesResponse(
            alloc,
            request_json,
            response_json,
        ) catch {
            alloc.free(response_json);
            std.Thread.sleep(10 * std.time.ns_per_ms);
            continue;
        };
        if (matches) return response_json;

        alloc.free(response_json);
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }

    try stderr.print(
        "Timed out waiting for workspace-control response from Ghostty\n",
        .{},
    );
    try stderr.flush();
    return error.IPCFailed;
}
