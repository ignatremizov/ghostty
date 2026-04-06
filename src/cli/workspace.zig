const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

const Action = @import("../cli.zig").ghostty.Action;
const apprt = @import("../apprt.zig");
const workspace_control_protocol = @import("../apprt/workspace_control_protocol.zig");
const args = @import("args.zig");
const build_config = @import("../build_config.zig");
const diagnostics = @import("diagnostics.zig");

const gtk_workspace_ipc = if (build_config.app_runtime == .gtk)
    @import("../apprt/gtk/ipc/workspace_control.zig")
else
    struct {};

const Method = workspace_control_protocol.Method;

fn deinitOptions(self: anytype) void {
    if (self._arena) |arena| arena.deinit();
    self.* = undefined;
}

fn helpOptions(_: anytype) !void {
    return Action.help_error;
}

fn printResponse(stderr: *std.Io.Writer, stdout: *std.Io.Writer, response_json: []const u8) !u8 {
    try stdout.print("{s}\n", .{response_json});
    return if (responseSucceeded(response_json))
        0
    else blk: {
        try stderr.flush();
        break :blk 1;
    };
}

fn responseSucceeded(response_json: []const u8) bool {
    var parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, response_json, .{}) catch {
        return false;
    };
    defer parsed.deinit();

    const object = switch (parsed.value) {
        .object => parsed.value.object,
        else => return false,
    };
    const ok = object.get("ok") orelse return false;
    return ok == .bool and ok.bool;
}

fn encodeRequestAlloc(
    alloc: Allocator,
    id: ?[]const u8,
    method: Method,
    params_json: []const u8,
) ![]u8 {
    return workspace_control_protocol.encodeRequestAlloc(alloc, id, method, params_json);
}

fn sendRequest(
    alloc: Allocator,
    stderr: *std.Io.Writer,
    stdout: *std.Io.Writer,
    target: apprt.ipc.Target,
    method: Method,
    params_json: []const u8,
) !u8 {
    if (comptime build_config.app_runtime != .gtk) {
        try stderr.print("+workspace-* is not supported on this platform.\n", .{});
        return 1;
    }

    const request_id = try std.fmt.allocPrint(alloc, "cli-{d}", .{std.time.milliTimestamp()});
    defer alloc.free(request_id);

    const request_json = try encodeRequestAlloc(
        alloc,
        request_id,
        method,
        params_json,
    );
    defer alloc.free(request_json);

    const response_json = gtk_workspace_ipc.workspaceControl(
        alloc,
        target,
        request_json,
    ) catch |err| switch (err) {
        error.IPCFailed => return 1,
        else => return err,
    };
    defer alloc.free(response_json);

    return printResponse(stderr, stdout, response_json);
}

fn encodeParamsAlloc(alloc: Allocator, value: anytype) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try std.json.Stringify.value(value, .{}, &out.writer);
    return out.toOwnedSlice();
}

fn encodeEmptyParamsAlloc(alloc: Allocator) ![]u8 {
    return alloc.dupe(u8, "{}");
}

fn targetForClass(class: ?[:0]const u8) apprt.ipc.Target {
    return if (class) |value| .{ .class = value } else .detect;
}

pub const ListOptions = struct {
    _arena: ?ArenaAllocator = null,
    _diagnostics: diagnostics.DiagnosticList = .{},
    class: ?[:0]const u8 = null,
    json: bool = false,

    pub fn deinit(self: *ListOptions) void {
        deinitOptions(self);
    }

    pub fn help(self: ListOptions) !void {
        return helpOptions(self);
    }
};

pub fn runList(alloc: Allocator) !u8 {
    var iter = try args.argsIterator(alloc);
    defer iter.deinit();

    var opts: ListOptions = .{};
    defer opts.deinit();
    try args.parse(ListOptions, alloc, &opts, &iter);

    var stdout_buf: [1024]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buf);
    const stdout = &stdout_writer.interface;

    var stderr_buf: [1024]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&stderr_buf);
    const stderr = &stderr_writer.interface;

    const params_json = try encodeEmptyParamsAlloc(alloc);
    defer alloc.free(params_json);

    const result = try sendRequest(
        alloc,
        stderr,
        stdout,
        targetForClass(opts.class),
        .workspace_list,
        params_json,
    );
    try stdout.flush();
    try stderr.flush();
    return result;
}

pub const OpenOptions = struct {
    _arena: ?ArenaAllocator = null,
    _diagnostics: diagnostics.DiagnosticList = .{},
    class: ?[:0]const u8 = null,
    json: bool = false,
    workspace: ?[:0]const u8 = null,
    create: bool = false,

    pub fn deinit(self: *OpenOptions) void {
        deinitOptions(self);
    }

    pub fn help(self: OpenOptions) !void {
        return helpOptions(self);
    }
};

pub fn runOpen(alloc: Allocator) !u8 {
    var iter = try args.argsIterator(alloc);
    defer iter.deinit();

    var opts: OpenOptions = .{};
    defer opts.deinit();
    try args.parse(OpenOptions, alloc, &opts, &iter);

    var stdout_buf: [1024]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buf);
    const stdout = &stdout_writer.interface;

    var stderr_buf: [1024]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&stderr_buf);
    const stderr = &stderr_writer.interface;

    const workspace = opts.workspace orelse {
        try stderr.print("--workspace is required\n", .{});
        try stderr.flush();
        return 1;
    };

    const params_json = try encodeParamsAlloc(alloc, .{
        .workspace = workspace,
        .create = opts.create,
    });
    defer alloc.free(params_json);

    const result = try sendRequest(
        alloc,
        stderr,
        stdout,
        targetForClass(opts.class),
        .workspace_open,
        params_json,
    );
    try stdout.flush();
    try stderr.flush();
    return result;
}

pub const SaveOptions = struct {
    _arena: ?ArenaAllocator = null,
    _diagnostics: diagnostics.DiagnosticList = .{},
    class: ?[:0]const u8 = null,
    json: bool = false,
    workspace: ?[:0]const u8 = null,

    pub fn deinit(self: *SaveOptions) void {
        deinitOptions(self);
    }

    pub fn help(self: SaveOptions) !void {
        return helpOptions(self);
    }
};

pub fn runSave(alloc: Allocator) !u8 {
    var iter = try args.argsIterator(alloc);
    defer iter.deinit();

    var opts: SaveOptions = .{};
    defer opts.deinit();
    try args.parse(SaveOptions, alloc, &opts, &iter);

    var stdout_buf: [1024]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buf);
    const stdout = &stdout_writer.interface;

    var stderr_buf: [1024]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&stderr_buf);
    const stderr = &stderr_writer.interface;

    const params_json = if (opts.workspace) |workspace| blk: {
        break :blk try encodeParamsAlloc(alloc, .{ .workspace = workspace });
    } else blk: {
        break :blk try encodeEmptyParamsAlloc(alloc);
    };
    defer alloc.free(params_json);

    const result = try sendRequest(
        alloc,
        stderr,
        stdout,
        targetForClass(opts.class),
        .workspace_save,
        params_json,
    );
    try stdout.flush();
    try stderr.flush();
    return result;
}

pub const RestoreOptions = struct {
    _arena: ?ArenaAllocator = null,
    _diagnostics: diagnostics.DiagnosticList = .{},
    class: ?[:0]const u8 = null,
    json: bool = false,
    workspace: ?[:0]const u8 = null,

    pub fn deinit(self: *RestoreOptions) void {
        deinitOptions(self);
    }

    pub fn help(self: RestoreOptions) !void {
        return helpOptions(self);
    }
};

pub fn runRestore(alloc: Allocator) !u8 {
    var iter = try args.argsIterator(alloc);
    defer iter.deinit();

    var opts: RestoreOptions = .{};
    defer opts.deinit();
    try args.parse(RestoreOptions, alloc, &opts, &iter);

    var stdout_buf: [1024]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buf);
    const stdout = &stdout_writer.interface;

    var stderr_buf: [1024]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&stderr_buf);
    const stderr = &stderr_writer.interface;

    const workspace = opts.workspace orelse {
        try stderr.print("--workspace is required\n", .{});
        try stderr.flush();
        return 1;
    };

    const params_json = try encodeParamsAlloc(alloc, .{ .workspace = workspace });
    defer alloc.free(params_json);

    const result = try sendRequest(
        alloc,
        stderr,
        stdout,
        targetForClass(opts.class),
        .workspace_restore,
        params_json,
    );
    try stdout.flush();
    try stderr.flush();
    return result;
}

pub const ListSessionsOptions = struct {
    _arena: ?ArenaAllocator = null,
    _diagnostics: diagnostics.DiagnosticList = .{},
    class: ?[:0]const u8 = null,
    json: bool = false,
    workspace: ?[:0]const u8 = null,

    pub fn deinit(self: *ListSessionsOptions) void {
        deinitOptions(self);
    }

    pub fn help(self: ListSessionsOptions) !void {
        return helpOptions(self);
    }
};

pub fn runListSessions(alloc: Allocator) !u8 {
    var iter = try args.argsIterator(alloc);
    defer iter.deinit();

    var opts: ListSessionsOptions = .{};
    defer opts.deinit();
    try args.parse(ListSessionsOptions, alloc, &opts, &iter);

    var stdout_buf: [1024]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buf);
    const stdout = &stdout_writer.interface;

    var stderr_buf: [1024]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&stderr_buf);
    const stderr = &stderr_writer.interface;

    const params_json = try encodeParamsAlloc(alloc, .{ .workspace = opts.workspace });
    defer alloc.free(params_json);

    const result = try sendRequest(
        alloc,
        stderr,
        stdout,
        targetForClass(opts.class),
        .session_list,
        params_json,
    );
    try stdout.flush();
    try stderr.flush();
    return result;
}

pub const FocusSessionOptions = struct {
    _arena: ?ArenaAllocator = null,
    _diagnostics: diagnostics.DiagnosticList = .{},
    class: ?[:0]const u8 = null,
    json: bool = false,
    session: ?[:0]const u8 = null,

    pub fn deinit(self: *FocusSessionOptions) void {
        deinitOptions(self);
    }

    pub fn help(self: FocusSessionOptions) !void {
        return helpOptions(self);
    }
};

pub fn runFocusSession(alloc: Allocator) !u8 {
    var iter = try args.argsIterator(alloc);
    defer iter.deinit();

    var opts: FocusSessionOptions = .{};
    defer opts.deinit();
    try args.parse(FocusSessionOptions, alloc, &opts, &iter);

    var stdout_buf: [1024]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buf);
    const stdout = &stdout_writer.interface;

    var stderr_buf: [1024]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&stderr_buf);
    const stderr = &stderr_writer.interface;

    const session = opts.session orelse {
        try stderr.print("--session is required\n", .{});
        try stderr.flush();
        return 1;
    };

    const params_json = try encodeParamsAlloc(alloc, .{ .session = session });
    defer alloc.free(params_json);

    const result = try sendRequest(
        alloc,
        stderr,
        stdout,
        targetForClass(opts.class),
        .session_focus,
        params_json,
    );
    try stdout.flush();
    try stderr.flush();
    return result;
}

pub const SplitDirection = enum {
    left,
    right,
    up,
    down,
};

pub const SplitOptions = struct {
    _arena: ?ArenaAllocator = null,
    _diagnostics: diagnostics.DiagnosticList = .{},
    class: ?[:0]const u8 = null,
    json: bool = false,
    session: ?[:0]const u8 = null,
    direction: ?SplitDirection = null,
    cwd: ?[:0]const u8 = null,
    command: ?[:0]const u8 = null,

    pub fn deinit(self: *SplitOptions) void {
        deinitOptions(self);
    }

    pub fn help(self: SplitOptions) !void {
        return helpOptions(self);
    }
};

pub fn runSplit(alloc: Allocator) !u8 {
    var iter = try args.argsIterator(alloc);
    defer iter.deinit();

    var opts: SplitOptions = .{};
    defer opts.deinit();
    try args.parse(SplitOptions, alloc, &opts, &iter);

    var stdout_buf: [1024]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buf);
    const stdout = &stdout_writer.interface;

    var stderr_buf: [1024]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&stderr_buf);
    const stderr = &stderr_writer.interface;

    const session = opts.session orelse {
        try stderr.print("--session is required\n", .{});
        try stderr.flush();
        return 1;
    };
    const direction = opts.direction orelse {
        try stderr.print("--direction is required\n", .{});
        try stderr.flush();
        return 1;
    };

    const params_json = try encodeParamsAlloc(alloc, .{
        .session = session,
        .direction = @tagName(direction),
        .cwd = opts.cwd,
        .command = opts.command,
    });
    defer alloc.free(params_json);

    const result = try sendRequest(
        alloc,
        stderr,
        stdout,
        targetForClass(opts.class),
        .session_split,
        params_json,
    );
    try stdout.flush();
    try stderr.flush();
    return result;
}

pub const CloseSessionOptions = struct {
    _arena: ?ArenaAllocator = null,
    _diagnostics: diagnostics.DiagnosticList = .{},
    class: ?[:0]const u8 = null,
    json: bool = false,
    session: ?[:0]const u8 = null,

    pub fn deinit(self: *CloseSessionOptions) void {
        deinitOptions(self);
    }

    pub fn help(self: CloseSessionOptions) !void {
        return helpOptions(self);
    }
};

pub fn runCloseSession(alloc: Allocator) !u8 {
    var iter = try args.argsIterator(alloc);
    defer iter.deinit();

    var opts: CloseSessionOptions = .{};
    defer opts.deinit();
    try args.parse(CloseSessionOptions, alloc, &opts, &iter);

    var stdout_buf: [1024]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buf);
    const stdout = &stdout_writer.interface;

    var stderr_buf: [1024]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&stderr_buf);
    const stderr = &stderr_writer.interface;

    const session = opts.session orelse {
        try stderr.print("--session is required\n", .{});
        try stderr.flush();
        return 1;
    };

    const params_json = try encodeParamsAlloc(alloc, .{ .session = session });
    defer alloc.free(params_json);

    const result = try sendRequest(
        alloc,
        stderr,
        stdout,
        targetForClass(opts.class),
        .session_close,
        params_json,
    );
    try stdout.flush();
    try stderr.flush();
    return result;
}

test "workspace cli responseSucceeded handles ok and invalid payloads" {
    const testing = std.testing;

    try testing.expect(responseSucceeded("{\"ok\":true,\"result\":{}}"));
    try testing.expect(!responseSucceeded("{\"ok\":false,\"error\":{\"code\":\"x\",\"message\":\"y\"}}"));
    try testing.expect(!responseSucceeded("not-json"));
}

test "workspace cli targetForClass maps class to ipc target" {
    const testing = std.testing;

    try testing.expectEqual(apprt.ipc.Target.detect, targetForClass(null));

    const target = targetForClass("ghostty-dev");
    switch (target) {
        .class => |value| try testing.expectEqualStrings("ghostty-dev", value),
        else => return error.TestUnexpectedResult,
    }
}

test "workspace cli encodeEmptyParamsAlloc encodes a JSON object" {
    const testing = std.testing;

    const params_json = try encodeEmptyParamsAlloc(testing.allocator);
    defer testing.allocator.free(params_json);

    try testing.expectEqualStrings("{}", params_json);
}

test "workspace cli encodes required V1 request envelopes" {
    const testing = std.testing;

    const cases = [_]struct {
        method: Method,
        params: []const u8,
        expected_method: []const u8,
        expected_params_fragment: []const u8,
    }{
        .{
            .method = .workspace_list,
            .params = "{}",
            .expected_method = "\"method\":\"workspace.list\"",
            .expected_params_fragment = "\"params\":{}",
        },
        .{
            .method = .workspace_open,
            .params = "{\"workspace\":\"work\",\"create\":true}",
            .expected_method = "\"method\":\"workspace.open\"",
            .expected_params_fragment = "\"params\":{\"workspace\":\"work\",\"create\":true}",
        },
        .{
            .method = .workspace_save,
            .params = "{\"workspace\":\"work\"}",
            .expected_method = "\"method\":\"workspace.save\"",
            .expected_params_fragment = "\"params\":{\"workspace\":\"work\"}",
        },
        .{
            .method = .workspace_restore,
            .params = "{\"workspace\":\"work\"}",
            .expected_method = "\"method\":\"workspace.restore\"",
            .expected_params_fragment = "\"params\":{\"workspace\":\"work\"}",
        },
        .{
            .method = .session_list,
            .params = "{\"workspace\":\"work\"}",
            .expected_method = "\"method\":\"session.list\"",
            .expected_params_fragment = "\"params\":{\"workspace\":\"work\"}",
        },
        .{
            .method = .session_focus,
            .params = "{\"session\":\"session:1\"}",
            .expected_method = "\"method\":\"session.focus\"",
            .expected_params_fragment = "\"params\":{\"session\":\"session:1\"}",
        },
        .{
            .method = .session_split,
            .params = "{\"session\":\"session:1\",\"direction\":\"right\",\"cwd\":\"/tmp\",\"command\":\"zsh\"}",
            .expected_method = "\"method\":\"session.split\"",
            .expected_params_fragment = "\"params\":{\"session\":\"session:1\",\"direction\":\"right\",\"cwd\":\"/tmp\",\"command\":\"zsh\"}",
        },
        .{
            .method = .session_close,
            .params = "{\"session\":\"session:1\"}",
            .expected_method = "\"method\":\"session.close\"",
            .expected_params_fragment = "\"params\":{\"session\":\"session:1\"}",
        },
    };

    for (cases) |case| {
        const request = try encodeRequestAlloc(
            testing.allocator,
            "cli-contract",
            case.method,
            case.params,
        );
        defer testing.allocator.free(request);

        try testing.expect(std.mem.indexOf(u8, request, "\"id\":\"cli-contract\"") != null);
        try testing.expect(std.mem.indexOf(u8, request, case.expected_method) != null);
        try testing.expect(std.mem.indexOf(u8, request, case.expected_params_fragment) != null);
    }
}

test "workspace cli encodeRequestAlloc rejects non-object params" {
    const testing = std.testing;

    try testing.expectError(
        error.InvalidFormat,
        encodeRequestAlloc(
            testing.allocator,
            "cli-contract",
            .workspace_list,
            "[]",
        ),
    );
}

test "workspace cli printResponse returns exit code for success and error payloads" {
    const testing = std.testing;

    var stdout_stream: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_stream.deinit();
    var stderr_stream: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_stream.deinit();

    try testing.expectEqual(
        @as(u8, 0),
        try printResponse(
            &stderr_stream.writer,
            &stdout_stream.writer,
            "{\"ok\":true,\"result\":{}}",
        ),
    );

    stdout_stream.clearRetainingCapacity();
    stderr_stream.clearRetainingCapacity();
    try testing.expectEqual(
        @as(u8, 1),
        try printResponse(
            &stderr_stream.writer,
            &stdout_stream.writer,
            "{\"ok\":false,\"error\":{\"code\":\"not_found\",\"message\":\"x\"}}",
        ),
    );
}
