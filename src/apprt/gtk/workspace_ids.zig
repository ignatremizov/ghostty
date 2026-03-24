const std = @import("std");

pub const Kind = enum {
    workspace,
    window,
    split,
    tab,
    session,
    surface,
    snapshot,

    pub fn prefix(self: Kind) []const u8 {
        return switch (self) {
            .workspace => "ws",
            .window => "win",
            .split => "split",
            .tab => "tab",
            .session => "session",
            .surface => "surface",
            .snapshot => "snapshot",
        };
    }
};

pub const WorkspaceId = Id(.workspace);
pub const WindowId = Id(.window);
pub const SplitId = Id(.split);
pub const TabId = Id(.tab);
pub const SessionId = Id(.session);
pub const SurfaceId = Id(.surface);
pub const SnapshotId = Id(.snapshot);

pub fn Id(comptime kind: Kind) type {
    return enum(u64) {
        _,

        pub const kind_value = kind;

        pub fn init(value: u64) @This() {
            std.debug.assert(value != 0);
            return @enumFromInt(value);
        }

        pub fn raw(self: @This()) u64 {
            return @intFromEnum(self);
        }

        pub fn format(self: @This(), buf: []u8) ![]const u8 {
            return std.fmt.bufPrint(buf, "{s}-{d}", .{ kind.prefix(), self.raw() });
        }

        pub fn jsonStringify(self: @This(), writer: anytype) !void {
            var buf: [32]u8 = undefined;
            const text = self.format(&buf) catch unreachable;
            try writer.write(text);
        }

        pub fn jsonParse(
            allocator: std.mem.Allocator,
            source: anytype,
            options: std.json.ParseOptions,
        ) !@This() {
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

            const parsed = parse(text) catch return error.InvalidEnumTag;
            return switch (parsed) {
                inline else => |value| {
                    if (@TypeOf(value) != @This()) return error.InvalidEnumTag;
                    return value;
                },
            };
        }
    };
}

pub const ParsedId = union(Kind) {
    workspace: WorkspaceId,
    window: WindowId,
    split: SplitId,
    tab: TabId,
    session: SessionId,
    surface: SurfaceId,
    snapshot: SnapshotId,
};

pub fn parse(text: []const u8) !ParsedId {
    inline for (std.meta.fields(Kind)) |field| {
        const kind: Kind = @enumFromInt(field.value);
        if (std.mem.startsWith(u8, text, kind.prefix()) and text.len > kind.prefix().len + 1 and text[kind.prefix().len] == '-') {
            const value = try std.fmt.parseInt(u64, text[kind.prefix().len + 1 ..], 10);
            if (value == 0) return error.InvalidWorkspaceId;
            return @unionInit(ParsedId, field.name, Id(kind).init(value));
        }
    }

    return error.InvalidWorkspaceId;
}

pub const Generator = struct {
    next_workspace: u64 = 1,
    next_window: u64 = 1,
    next_split: u64 = 1,
    next_tab: u64 = 1,
    next_session: u64 = 1,
    next_surface: u64 = 1,
    next_snapshot: u64 = 1,

    pub fn next(self: *Generator, comptime kind: Kind) Id(kind) {
        const field_name = switch (kind) {
            .workspace => "next_workspace",
            .window => "next_window",
            .split => "next_split",
            .tab => "next_tab",
            .session => "next_session",
            .surface => "next_surface",
            .snapshot => "next_snapshot",
        };
        const current = @field(self, field_name);
        @field(self, field_name) = current + 1;
        return Id(kind).init(current);
    }

    pub fn observe(self: *Generator, value: anytype) void {
        const T = @TypeOf(value);
        const kind: Kind = T.kind_value;
        const field_name = switch (kind) {
            .workspace => "next_workspace",
            .window => "next_window",
            .split => "next_split",
            .tab => "next_tab",
            .session => "next_session",
            .surface => "next_surface",
            .snapshot => "next_snapshot",
        };
        const next_value = value.raw() + 1;
        if (@field(self, field_name) < next_value) @field(self, field_name) = next_value;
    }
};

test "workspace ids format and parse" {
    const testing = std.testing;

    var buf: [32]u8 = undefined;
    const workspace = WorkspaceId.init(42);
    try testing.expectEqualStrings("ws-42", try workspace.format(&buf));

    const parsed = try parse("session-7");
    try testing.expectEqual(SessionId.init(7), parsed.session);
}

test "workspace ids generator stays monotonic after observe" {
    const testing = std.testing;

    var generator: Generator = .{};
    try testing.expectEqual(WindowId.init(1), generator.next(.window));
    generator.observe(WindowId.init(9));
    try testing.expectEqual(WindowId.init(10), generator.next(.window));
    try testing.expectEqual(WindowId.init(11), generator.next(.window));
}
