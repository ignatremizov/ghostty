const std = @import("std");

pub const FocusBehavior = enum {
    no_focus_change,
    may_change_focus,
};

pub const Method = enum {
    workspace_list,
    workspace_open,
    workspace_save,
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
            .workspace_save => "workspace.save",
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
            => .may_change_focus,
            else => .no_focus_change,
        };
    }
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

fn expectJsonObject(json: []const u8) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, std.heap.smp_allocator, json, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidFormat;
}
