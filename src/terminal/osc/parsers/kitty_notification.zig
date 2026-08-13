const std = @import("std");

const Parser = @import("../../osc.zig").Parser;
const Command = @import("../../osc.zig").Command;
const encoding = @import("../encoding.zig");

const log = std.log.scoped(.osc_kitty_notification);

const PayloadKind = enum {
    title,
    body,
    control,
    ignore,
};

pub fn parse(parser: *Parser, _: ?u8) ?*Command {
    const cap = if (parser.capture) |*c| c else {
        parser.state = .invalid;
        return null;
    };

    // Ensure sentinel termination.
    cap.writer.writeByte(0) catch {
        parser.state = .invalid;
        return null;
    };

    var data = cap.trailing();
    if (data.len == 0) {
        parser.state = .invalid;
        return null;
    }

    // Drop sentinel.
    data = data[0 .. data.len - 1];

    const meta_end = std.mem.indexOfScalar(u8, data, ';') orelse {
        parser.state = .invalid;
        return null;
    };

    const meta = data[0..meta_end];
    const payload = data[meta_end + 1 ..];

    var payload_kind: PayloadKind = .title;
    var done = true;
    var base64 = false;
    var id: ?[]const u8 = null;

    if (meta.len > 0) {
        var it = std.mem.splitScalar(u8, meta, ':');
        while (it.next()) |part| {
            if (part.len == 0) continue;
            const eq = std.mem.indexOfScalar(u8, part, '=') orelse {
                parser.state = .invalid;
                return null;
            };
            if (eq != 1) {
                parser.state = .invalid;
                return null;
            }
            const key = part[0];
            const value = part[eq + 1 ..];
            switch (key) {
                'p' => payload_kind = parsePayloadKind(value),
                'd' => done = parseBool(value, true),
                'e' => base64 = parseBool(value, false),
                'i' => {
                    if (!isValidId(value)) {
                        parser.state = .invalid;
                        return null;
                    }
                    id = value;
                },
                else => {},
            }
        }
    }

    const pending = &parser.kitty_notification_pending;

    if (id) |value| {
        if (value.len > pending.id.len) {
            parser.state = .invalid;
            return null;
        }
    }

    if (payload_kind == .control) {
        resetPendingForControlPayload(pending, id);
        return null;
    }

    if (payload_kind == .ignore) {
        return null;
    }

    if (!base64 and !encoding.isSafeUtf8(payload)) {
        parser.state = .invalid;
        return null;
    }

    if (id) |value| {
        if (!pending.active or !std.mem.eql(u8, pending.idSlice(), value)) {
            pending.reset();
            pending.active = true;
            pending.id_len = value.len;
            @memcpy(pending.id[0..pending.id_len], value[0..pending.id_len]);
        }
    } else {
        pending.reset();
        pending.active = true;
    }

    if (!appendPayload(pending, payload_kind, payload, base64)) {
        parser.state = .invalid;
        return null;
    }

    if (!done) {
        return null;
    }

    if (pending.title_len == 0 and pending.body_len == 0) {
        pending.reset();
        return null;
    }

    if (!finalizePayload(&pending.title, &pending.title_len, pending.title_base64)) {
        parser.state = .invalid;
        pending.reset();
        return null;
    }
    if (!finalizePayload(&pending.body, &pending.body_len, pending.body_base64)) {
        parser.state = .invalid;
        pending.reset();
        return null;
    }

    pending.title[pending.title_len] = 0;
    pending.body[pending.body_len] = 0;

    var title: [:0]const u8 = pending.title[0..pending.title_len :0];
    var body: [:0]const u8 = pending.body[0..pending.body_len :0];

    if (pending.title_len == 0 and pending.body_len > 0) {
        title = pending.body[0..pending.body_len :0];
        body = "";
    }

    parser.command = .{
        .show_desktop_notification = .{
            .title = title,
            .body = body,
        },
    };

    // Clear lengths for next notification but keep buffers intact for command slices.
    pending.reset();
    return &parser.command;
}

fn parsePayloadKind(value: []const u8) PayloadKind {
    if (std.mem.eql(u8, value, "title")) return .title;
    if (std.mem.eql(u8, value, "body")) return .body;
    if (std.mem.eql(u8, value, "close")) return .control;
    if (std.mem.eql(u8, value, "alive")) return .control;
    return .ignore;
}

fn resetPendingForControlPayload(
    pending: *Parser.KittyNotificationPending,
    id: ?[]const u8,
) void {
    if (!pending.active) return;
    const value = id orelse return;

    if (std.mem.eql(u8, pending.idSlice(), value)) pending.reset();
}

fn parseBool(value: []const u8, default: bool) bool {
    if (value.len == 0) return default;
    return switch (value[0]) {
        '0' => false,
        '1' => true,
        else => default,
    };
}

fn isValidId(value: []const u8) bool {
    if (value.len == 0) return false;
    for (value) |c| {
        if (std.ascii.isAlphanumeric(c)) continue;
        switch (c) {
            '-', '_', '+', '.' => continue,
            else => return false,
        }
    }
    return true;
}

fn appendPayload(
    pending: *Parser.KittyNotificationPending,
    kind: PayloadKind,
    payload: []const u8,
    base64: bool,
) bool {
    switch (kind) {
        .title => {
            if (pending.title_seen and pending.title_base64 != base64) return false;
            pending.title_seen = true;
            pending.title_base64 = base64;
            return appendBuffer(&pending.title, &pending.title_len, payload);
        },
        .body => {
            if (pending.body_seen and pending.body_base64 != base64) return false;
            pending.body_seen = true;
            pending.body_base64 = base64;
            return appendBuffer(&pending.body, &pending.body_len, payload);
        },
        .control => unreachable,
        .ignore => return true,
    }
}

fn finalizePayload(buffer: *[Parser.MAX_BUF + 1]u8, len: *usize, base64: bool) bool {
    if (!base64) return true;

    const decoder = std.base64.standard.Decoder;
    const decoded_len = decoder.calcSizeForSlice(buffer[0..len.*]) catch return false;
    if (decoded_len > len.*) return false;
    _ = decoder.decode(buffer[0..decoded_len], buffer[0..len.*]) catch return false;
    if (!encoding.isSafeUtf8(buffer[0..decoded_len])) return false;
    len.* = decoded_len;
    return true;
}

fn appendBuffer(buffer: *[Parser.MAX_BUF + 1]u8, len: *usize, payload: []const u8) bool {
    if (payload.len == 0) return true;
    if (len.* + payload.len > buffer.len - 1) {
        log.warn("kitty notification payload too large (total_len={d})", .{len.* + payload.len});
        return false;
    }
    @memcpy(buffer[len.* .. len.* + payload.len], payload);
    len.* += payload.len;
    return true;
}

test "OSC 99: kitty notification with title only" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "99;;Hello Kitty";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .show_desktop_notification);
    try testing.expectEqualStrings("Hello Kitty", cmd.show_desktop_notification.title);
    try testing.expectEqualStrings("", cmd.show_desktop_notification.body);
}

test "OSC 99: kitty notification with title and body chunks" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const title = "99;i=abc:d=0:p=title;Kitty Title";
    for (title) |ch| p.next(ch);
    try testing.expect(p.end('\x1b') == null);
    p.reset();

    const body = "99;i=abc:p=body;Kitty Body";
    for (body) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .show_desktop_notification);
    try testing.expectEqualStrings("Kitty Title", cmd.show_desktop_notification.title);
    try testing.expectEqualStrings("Kitty Body", cmd.show_desktop_notification.body);
}

test "OSC 99: close payload clears pending chunks for matching id" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const partial = "99;i=abc:d=0:p=title;Kitty Title";
    for (partial) |ch| p.next(ch);
    try testing.expect(p.end('\x1b') == null);
    p.reset();

    const close = "99;i=abc:p=close;";
    for (close) |ch| p.next(ch);
    try testing.expect(p.end('\x1b') == null);
    p.reset();

    const replacement = "99;i=abc:p=body;Fresh Body";
    for (replacement) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .show_desktop_notification);
    try testing.expectEqualStrings("Fresh Body", cmd.show_desktop_notification.title);
    try testing.expectEqualStrings("", cmd.show_desktop_notification.body);
}

test "OSC 99: base64 title and body chunks decode as UTF-8" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const title = "99;i=abc:d=0:p=title:e=1;S2l0dHkgVGl0bGU=";
    for (title) |ch| p.next(ch);
    try testing.expect(p.end('\x1b') == null);
    p.reset();

    const body = "99;i=abc:p=body:e=1;S2l0dHkgQm9keQ==";
    for (body) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .show_desktop_notification);
    try testing.expectEqualStrings("Kitty Title", cmd.show_desktop_notification.title);
    try testing.expectEqualStrings("Kitty Body", cmd.show_desktop_notification.body);
}

test "OSC 99: base64 title decodes after chunk reassembly" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const first = "99;i=abc:d=0:p=title:e=1;S2l0";
    for (first) |ch| p.next(ch);
    try testing.expect(p.end('\x1b') == null);
    p.reset();

    const second = "99;i=abc:p=title:e=1;dHkgVGl0bGU=";
    for (second) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .show_desktop_notification);
    try testing.expectEqualStrings("Kitty Title", cmd.show_desktop_notification.title);
    try testing.expectEqualStrings("", cmd.show_desktop_notification.body);
}

test "OSC 99: invalid base64 payload marks parser invalid" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "99;p=title:e=1;***";
    for (input) |ch| p.next(ch);

    try testing.expect(p.end('\x1b') == null);
    try testing.expectEqual(.invalid, p.state);
}

test "OSC 99: close payload without id is a no-op" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const partial = "99;i=abc:d=0:p=title;Kitty Title";
    for (partial) |ch| p.next(ch);
    try testing.expect(p.end('\x1b') == null);
    p.reset();

    const close = "99;p=close;";
    for (close) |ch| p.next(ch);
    try testing.expect(p.end('\x1b') == null);
    p.reset();

    const body = "99;i=abc:p=body;Kitty Body";
    for (body) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .show_desktop_notification);
    try testing.expectEqualStrings("Kitty Title", cmd.show_desktop_notification.title);
    try testing.expectEqualStrings("Kitty Body", cmd.show_desktop_notification.body);
}

test "OSC 99: oversized ids are rejected" {
    const testing = std.testing;

    var p: Parser = .init(null);
    const id = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const input = try std.fmt.allocPrint(testing.allocator, "99;i={s};Hello", .{id});
    defer testing.allocator.free(input);
    for (input) |ch| p.next(ch);

    try testing.expect(p.end('\x1b') == null);
    try testing.expectEqual(.invalid, p.state);
}

test "OSC 99: oversized control ids are rejected" {
    const testing = std.testing;

    var p: Parser = .init(null);
    const id = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const input = try std.fmt.allocPrint(testing.allocator, "99;i={s}:p=close;", .{id});
    defer testing.allocator.free(input);
    for (input) |ch| p.next(ch);

    try testing.expect(p.end('\x1b') == null);
    try testing.expectEqual(.invalid, p.state);
}

test "OSC 99: ids containing colons are rejected" {
    const testing = std.testing;

    var p: Parser = .init(null);
    const input = "99;i=a:b;Hello Kitty";
    for (input) |ch| p.next(ch);

    try testing.expect(p.end('\x1b') == null);
    try testing.expectEqual(Parser.State.invalid, p.state);
}

test "OSC 99: full-size payload chunk is accepted" {
    const testing = std.testing;

    var p: Parser = .init(testing.allocator);
    defer p.deinit();
    var payload: [Parser.MAX_BUF]u8 = undefined;
    @memset(&payload, 'a');

    const prefix = "99;;";
    for (prefix) |ch| p.next(ch);
    for (payload) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .show_desktop_notification);
    try testing.expectEqual(@as(usize, Parser.MAX_BUF), cmd.show_desktop_notification.title.len);
}

test "OSC 99: malformed meta segment is rejected" {
    const testing = std.testing;

    var p: Parser = .init(null);
    const input = "99;i=abc:def=1;Hello Kitty";
    for (input) |ch| p.next(ch);

    try testing.expect(p.end('\x1b') == null);
    try testing.expectEqual(Parser.State.invalid, p.state);
}

test "OSC 99: mixed encoding after empty chunk is rejected" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const empty_base64 = "99;i=abc:d=0:e=1:p=title;";
    for (empty_base64) |ch| p.next(ch);
    try testing.expect(p.end('\x1b') == null);
    p.reset();

    const plain = "99;i=abc:e=0:p=title;Hello";
    for (plain) |ch| p.next(ch);

    try testing.expect(p.end('\x1b') == null);
    try testing.expectEqual(Parser.State.invalid, p.state);
}
