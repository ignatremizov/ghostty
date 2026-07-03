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
const CommandUsageError = error{CommandUsage};

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

    const request_id = try allocRequestId(alloc);
    defer alloc.free(request_id);

    const request_json = try workspace_control_protocol.encodeRequestAlloc(
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

fn allocRequestId(alloc: Allocator) ![]u8 {
    var random_bytes: [8]u8 = undefined;
    std.crypto.random.bytes(&random_bytes);
    const random_hex = std.fmt.bytesToHex(random_bytes, .lower);
    return std.fmt.allocPrint(
        alloc,
        "cli-{d}-{s}",
        .{ std.time.milliTimestamp(), &random_hex },
    );
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

fn printUsageError(stderr: *std.Io.Writer, message: []const u8) !void {
    try stderr.print("{s}\n", .{message});
}

fn runCommand(
    alloc: Allocator,
    comptime Options: type,
    comptime method: Method,
    comptime buildParams: fn (Allocator, *std.Io.Writer, Options) anyerror![]u8,
) !u8 {
    var iter = try args.argsIterator(alloc);
    defer iter.deinit();

    var opts: Options = .{};
    defer opts.deinit();
    try args.parse(Options, alloc, &opts, &iter);

    var stdout_buf: [1024]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buf);
    var stderr_buf: [1024]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&stderr_buf);

    const params_json = buildParams(alloc, &stderr_writer.interface, opts) catch |err| switch (err) {
        error.CommandUsage => {
            try stdout_writer.interface.flush();
            try stderr_writer.interface.flush();
            return 1;
        },
        else => return err,
    };
    defer alloc.free(params_json);

    const result = try sendRequest(
        alloc,
        &stderr_writer.interface,
        &stdout_writer.interface,
        targetForClass(opts.class),
        method,
        params_json,
    );
    try stdout_writer.interface.flush();
    try stderr_writer.interface.flush();
    return result;
}

fn targetForClass(class: ?[:0]const u8) apprt.ipc.Target {
    return if (class) |value| .{ .class = value } else .detect;
}

pub const ListOptions = struct {
    _arena: ?ArenaAllocator = null,
    _diagnostics: diagnostics.DiagnosticList = .{},
    class: ?[:0]const u8 = null,

    pub fn deinit(self: *ListOptions) void {
        deinitOptions(self);
    }

    pub fn help(self: ListOptions) !void {
        return helpOptions(self);
    }
};

/// Query the running Ghostty instance for its visible and restorable
/// workspaces and print the JSON workspace-control response.
pub fn runList(alloc: Allocator) !u8 {
    return runCommand(alloc, ListOptions, .workspace_list, buildListParams);
}

pub const OpenOptions = struct {
    _arena: ?ArenaAllocator = null,
    _diagnostics: diagnostics.DiagnosticList = .{},
    class: ?[:0]const u8 = null,
    workspace: ?[:0]const u8 = null,
    create: bool = false,

    pub fn deinit(self: *OpenOptions) void {
        deinitOptions(self);
    }

    pub fn help(self: OpenOptions) !void {
        return helpOptions(self);
    }
};

/// Open an existing workspace in the running Ghostty instance, or create it
/// when `--create` is supplied, and print the JSON workspace-control response.
pub fn runOpen(alloc: Allocator) !u8 {
    return runCommand(alloc, OpenOptions, .workspace_open, buildOpenParams);
}

pub const SaveOptions = struct {
    _arena: ?ArenaAllocator = null,
    _diagnostics: diagnostics.DiagnosticList = .{},
    class: ?[:0]const u8 = null,
    workspace: ?[:0]const u8 = null,

    pub fn deinit(self: *SaveOptions) void {
        deinitOptions(self);
    }

    pub fn help(self: SaveOptions) !void {
        return helpOptions(self);
    }
};

/// Save the current live snapshot for a workspace in the running Ghostty
/// instance and print the JSON workspace-control response.
pub fn runSave(alloc: Allocator) !u8 {
    return runCommand(alloc, SaveOptions, .workspace_save, buildSaveParams);
}

pub const RestoreOptions = struct {
    _arena: ?ArenaAllocator = null,
    _diagnostics: diagnostics.DiagnosticList = .{},
    class: ?[:0]const u8 = null,
    workspace: ?[:0]const u8 = null,

    pub fn deinit(self: *RestoreOptions) void {
        deinitOptions(self);
    }

    pub fn help(self: RestoreOptions) !void {
        return helpOptions(self);
    }
};

/// Restore the latest saved snapshot for a workspace in the running Ghostty
/// instance and print the JSON workspace-control response.
pub fn runRestore(alloc: Allocator) !u8 {
    return runCommand(alloc, RestoreOptions, .workspace_restore, buildRestoreParams);
}

pub const ListSessionsOptions = struct {
    _arena: ?ArenaAllocator = null,
    _diagnostics: diagnostics.DiagnosticList = .{},
    class: ?[:0]const u8 = null,
    workspace: ?[:0]const u8 = null,

    pub fn deinit(self: *ListSessionsOptions) void {
        deinitOptions(self);
    }

    pub fn help(self: ListSessionsOptions) !void {
        return helpOptions(self);
    }
};

/// List sessions for a workspace, or for the currently selected workspace
/// when `--workspace` is omitted, and print the JSON response.
pub fn runListSessions(alloc: Allocator) !u8 {
    return runCommand(alloc, ListSessionsOptions, .session_list, buildListSessionsParams);
}

pub const FocusSessionOptions = struct {
    _arena: ?ArenaAllocator = null,
    _diagnostics: diagnostics.DiagnosticList = .{},
    class: ?[:0]const u8 = null,
    session: ?[:0]const u8 = null,

    pub fn deinit(self: *FocusSessionOptions) void {
        deinitOptions(self);
    }

    pub fn help(self: FocusSessionOptions) !void {
        return helpOptions(self);
    }
};

/// Focus a target session in the running Ghostty instance and print the JSON
/// workspace-control response.
pub fn runFocusSession(alloc: Allocator) !u8 {
    return runCommand(alloc, FocusSessionOptions, .session_focus, buildFocusSessionParams);
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

/// Create a Ghostty-native split from a target session and print the JSON
/// workspace-control response.
pub fn runSplit(alloc: Allocator) !u8 {
    return runCommand(alloc, SplitOptions, .session_split, buildSplitParams);
}

pub const CloseSessionOptions = struct {
    _arena: ?ArenaAllocator = null,
    _diagnostics: diagnostics.DiagnosticList = .{},
    class: ?[:0]const u8 = null,
    session: ?[:0]const u8 = null,

    pub fn deinit(self: *CloseSessionOptions) void {
        deinitOptions(self);
    }

    pub fn help(self: CloseSessionOptions) !void {
        return helpOptions(self);
    }
};

/// Close a target session in the running Ghostty instance and print the JSON
/// workspace-control response.
pub fn runCloseSession(alloc: Allocator) !u8 {
    return runCommand(alloc, CloseSessionOptions, .session_close, buildCloseSessionParams);
}

fn buildListParams(alloc: Allocator, _: *std.Io.Writer, _: ListOptions) ![]u8 {
    return encodeEmptyParamsAlloc(alloc);
}

fn buildOpenParams(alloc: Allocator, stderr: *std.Io.Writer, opts: OpenOptions) ![]u8 {
    const workspace = opts.workspace orelse {
        try printUsageError(stderr, "--workspace is required");
        return error.CommandUsage;
    };
    return encodeParamsAlloc(alloc, .{ .workspace = workspace, .create = opts.create });
}

fn buildSaveParams(alloc: Allocator, _: *std.Io.Writer, opts: SaveOptions) ![]u8 {
    return if (opts.workspace) |workspace|
        encodeParamsAlloc(alloc, .{ .workspace = workspace })
    else
        encodeEmptyParamsAlloc(alloc);
}

fn buildRestoreParams(alloc: Allocator, stderr: *std.Io.Writer, opts: RestoreOptions) ![]u8 {
    const workspace = opts.workspace orelse {
        try printUsageError(stderr, "--workspace is required");
        return error.CommandUsage;
    };
    return encodeParamsAlloc(alloc, .{ .workspace = workspace });
}

fn buildListSessionsParams(alloc: Allocator, _: *std.Io.Writer, opts: ListSessionsOptions) ![]u8 {
    return encodeParamsAlloc(alloc, .{ .workspace = opts.workspace });
}

fn buildFocusSessionParams(alloc: Allocator, stderr: *std.Io.Writer, opts: FocusSessionOptions) ![]u8 {
    const session = opts.session orelse {
        try printUsageError(stderr, "--session is required");
        return error.CommandUsage;
    };
    return encodeParamsAlloc(alloc, .{ .session = session });
}

fn buildSplitParams(alloc: Allocator, stderr: *std.Io.Writer, opts: SplitOptions) ![]u8 {
    const session = opts.session orelse {
        try printUsageError(stderr, "--session is required");
        return error.CommandUsage;
    };
    const direction = opts.direction orelse {
        try printUsageError(stderr, "--direction is required");
        return error.CommandUsage;
    };
    return encodeParamsAlloc(alloc, .{
        .session = session,
        .direction = @tagName(direction),
        .cwd = opts.cwd,
        .command = opts.command,
    });
}

fn buildCloseSessionParams(alloc: Allocator, stderr: *std.Io.Writer, opts: CloseSessionOptions) ![]u8 {
    const session = opts.session orelse {
        try printUsageError(stderr, "--session is required");
        return error.CommandUsage;
    };
    return encodeParamsAlloc(alloc, .{ .session = session });
}

pub fn runAction(action: Action, alloc: Allocator) !u8 {
    return switch (action) {
        .@"workspace-list" => runList(alloc),
        .@"workspace-open" => runOpen(alloc),
        .@"workspace-save" => runSave(alloc),
        .@"workspace-restore" => runRestore(alloc),
        .@"workspace-list-sessions" => runListSessions(alloc),
        .@"workspace-focus-session" => runFocusSession(alloc),
        .@"workspace-split" => runSplit(alloc),
        .@"workspace-close-session" => runCloseSession(alloc),
        else => unreachable,
    };
}

pub fn optionsForAction(comptime action: Action) type {
    return switch (action) {
        .@"workspace-list" => ListOptions,
        .@"workspace-open" => OpenOptions,
        .@"workspace-save" => SaveOptions,
        .@"workspace-restore" => RestoreOptions,
        .@"workspace-list-sessions" => ListSessionsOptions,
        .@"workspace-focus-session" => FocusSessionOptions,
        .@"workspace-split" => SplitOptions,
        .@"workspace-close-session" => CloseSessionOptions,
        else => unreachable,
    };
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
        const request = try workspace_control_protocol.encodeRequestAlloc(
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
        workspace_control_protocol.encodeRequestAlloc(
            testing.allocator,
            "cli-contract",
            .workspace_list,
            "[]",
        ),
    );
}

test "workspace cli allocRequestId adds random suffix" {
    const testing = std.testing;

    const request_id = try allocRequestId(testing.allocator);
    defer testing.allocator.free(request_id);

    try testing.expect(std.mem.startsWith(u8, request_id, "cli-"));
    try testing.expect(std.mem.count(u8, request_id, "-") >= 2);
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
