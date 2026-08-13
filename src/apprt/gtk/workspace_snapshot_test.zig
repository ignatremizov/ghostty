const std = @import("std");
const builtin = @import("builtin");
const ids = @import("workspace_ids.zig");
const model = @import("workspace_model.zig");
const registry = @import("workspace_registry.zig");
const snapshot = @import("workspace_snapshot.zig");
const storage_mod = @import("workspace_storage.zig");

const fixture_splits = [_]snapshot.SplitRecord{.{
    .split_id = ids.SplitId.init(1),
    .window_id = ids.WindowId.init(1),
    .ordinal = 0,
    .root_layout_node_id = "split-1-root",
}};

const fixture_tabs = [_]snapshot.TabRecord{.{
    .tab_id = ids.TabId.init(1),
    .ordinal = 0,
    .title_override = "Main",
}};

const fixture_layout = [_]snapshot.LayoutNodeRecord{
    .{
        .layout_node_id = "split-1-root",
        .tab_id = ids.TabId.init(1),
        .node_type = .split_root,
        .child_ids = &.{"root-1"},
    },
    .{
        .layout_node_id = "root-1",
        .tab_id = ids.TabId.init(1),
        .node_type = .tab_root,
        .child_ids = &.{"leaf-1"},
        .is_selected = true,
    },
    .{
        .layout_node_id = "leaf-1",
        .tab_id = ids.TabId.init(1),
        .node_type = .session_leaf,
        .session_id = ids.SessionId.init(1),
    },
};

const fixture_sessions = [_]snapshot.SessionRecord{.{
    .session_id = ids.SessionId.init(1),
    .tab_id = ids.TabId.init(1),
    .cwd = "/home/ignat/code/ghostty",
    .command = .{ .argv = &.{ "zig", "build" } },
    .env_overrides = &.{.{ .key = "FOO", .value = "bar" }},
    .title_override = "shell",
    .focus_preferred = true,
}};

fn buildSnapshot() snapshot.Snapshot {
    return .{
        .snapshot_id = ids.SnapshotId.init(1),
        .saved_at = "2026-03-22T12:00:00Z",
        .workspace = .{
            .workspace_id = ids.WorkspaceId.init(1),
            .workspace_key = "workspace-key-1",
            .name = "Developer Workspace",
            .layout_root_node_id = "split-1-root",
            .selected_window_id = ids.WindowId.init(1),
            .selected_split_id = ids.SplitId.init(1),
            .selected_tab_id = ids.TabId.init(1),
            .selected_session_id = ids.SessionId.init(1),
        },
        .splits = &fixture_splits,
        .tabs = &fixture_tabs,
        .layout = &fixture_layout,
        .sessions = &fixture_sessions,
        .restore_results = .{
            .restored_workspace_id = ids.WorkspaceId.init(1),
            .restored_session_ids = &.{ids.SessionId.init(1)},
            .failed_sessions = &.{},
            .selection_fallback = .{
                .window_id = ids.WindowId.init(1),
                .tab_id = ids.TabId.init(1),
                .session_id = ids.SessionId.init(1),
                .reason = "selected_session_missing",
            },
        },
    };
}

test "workspace snapshot formats UTC timestamps from epoch seconds" {
    const testing = std.testing;

    const formatted = try snapshot.formatUtcTimestampAlloc(testing.allocator, 1625159473);
    defer testing.allocator.free(formatted);

    try testing.expectEqualStrings("2021-07-01T17:11:13Z", formatted);
}

test "workspace snapshot current UTC timestamp is RFC3339 and non-placeholder" {
    const testing = std.testing;

    const formatted = try snapshot.currentUtcTimestampAlloc(testing.allocator);
    defer testing.allocator.free(formatted);

    try testing.expectEqual(@as(usize, 20), formatted.len);
    try testing.expectEqual(@as(u8, '-'), formatted[4]);
    try testing.expectEqual(@as(u8, '-'), formatted[7]);
    try testing.expectEqual(@as(u8, 'T'), formatted[10]);
    try testing.expectEqual(@as(u8, ':'), formatted[13]);
    try testing.expectEqual(@as(u8, ':'), formatted[16]);
    try testing.expectEqual(@as(u8, 'Z'), formatted[19]);
    try testing.expect(!std.mem.eql(u8, formatted, "2026-03-22T00:00:00Z"));
}

test "workspace snapshot encodes schema-shaped json" {
    const testing = std.testing;

    const encoded = try buildSnapshot().encodeAlloc(testing.allocator);
    defer testing.allocator.free(encoded);

    try testing.expect(std.mem.indexOf(u8, encoded, "\"version\": 1") != null);
    try testing.expect(std.mem.indexOf(u8, encoded, "\"snapshot_id\": \"snapshot-1\"") != null);
    try testing.expect(std.mem.indexOf(u8, encoded, "\"workspace_id\": \"ws-1\"") != null);
    try testing.expect(std.mem.indexOf(u8, encoded, "\"workspace_key\": \"workspace-key-1\"") != null);
    try testing.expect(std.mem.indexOf(u8, encoded, "\"selected_split_id\": \"split-1\"") != null);
    try testing.expect(std.mem.indexOf(u8, encoded, "\"splits\": [") != null);
    try testing.expect(std.mem.indexOf(u8, encoded, "\"root_layout_node_id\": \"split-1-root\"") != null);
    try testing.expect(std.mem.indexOf(u8, encoded, "\"tab_ids\": [") == null);
    try testing.expect(std.mem.indexOf(u8, encoded, "\"root_layout_node_id\": \"root-1\"") == null);
    try testing.expect(std.mem.indexOf(u8, encoded, "\"node_type\": \"split-root\"") != null);
    try testing.expect(std.mem.indexOf(u8, encoded, "\"node_type\": \"tab-root\"") != null);
    try testing.expect(std.mem.indexOf(u8, encoded, "\"command\": [") != null);
    try testing.expect(std.mem.indexOf(u8, encoded, "\"env_overrides\": [") != null);
    try testing.expect(std.mem.indexOf(u8, encoded, "\"scrollback\"") == null);
}

test "workspace snapshot decode frees partial malformed json" {
    const testing = std.testing;
    const malformed =
        \\{"version":1,"snapshot_id":"snapshot-1","saved_at":"2026-03-22T12:00:00Z",
        \\"workspace":{"workspace_id":"ws-1","name":"incomplete
    ;
    try testing.expectError(
        error.UnexpectedEndOfInput,
        snapshot.Snapshot.decodeAlloc(testing.allocator, malformed),
    );
}

fn testSnapshotDecodeAllocationFailures(
    alloc: std.mem.Allocator,
    encoded: []const u8,
) !void {
    const decoded = try snapshot.Snapshot.decodeAlloc(alloc, encoded);
    defer decoded.deinit(alloc);
}

test "workspace snapshot decode cleans up allocation failures" {
    const testing = std.testing;
    const encoded = try buildSnapshot().encodeAlloc(testing.allocator);
    defer testing.allocator.free(encoded);

    try testing.checkAllAllocationFailures(
        testing.allocator,
        testSnapshotDecodeAllocationFailures,
        .{encoded},
    );
}

test "workspace snapshot rejects future versions" {
    const testing = std.testing;

    const encoded = try buildSnapshot().encodeAlloc(testing.allocator);
    defer testing.allocator.free(encoded);
    const version = std.mem.indexOf(u8, encoded, "\"version\": 1") orelse
        return error.MissingFixtureVersion;
    encoded[version + "\"version\": ".len] = '2';

    try testing.expectError(
        error.InvalidSnapshotVersion,
        snapshot.Snapshot.decodeAlloc(testing.allocator, encoded),
    );
}

test "workspace snapshot rejects layout cycles" {
    const testing = std.testing;

    const cyclic_layout = [_]snapshot.LayoutNodeRecord{
        .{
            .layout_node_id = "split-1-root",
            .node_type = .split_root,
            .child_ids = &.{"root-1"},
        },
        .{
            .layout_node_id = "root-1",
            .tab_id = ids.TabId.init(1),
            .node_type = .tab_root,
            .child_ids = &.{"leaf-1"},
        },
        .{
            .layout_node_id = "leaf-1",
            .tab_id = ids.TabId.init(1),
            .node_type = .session_leaf,
            .session_id = ids.SessionId.init(1),
        },
        .{
            .layout_node_id = "cycle-a",
            .node_type = .split,
            .split_direction = .right,
            .child_ids = &.{"cycle-b"},
        },
        .{
            .layout_node_id = "cycle-b",
            .node_type = .split,
            .split_direction = .down,
            .child_ids = &.{"cycle-a"},
        },
    };
    var value = buildSnapshot();
    value.layout = &cyclic_layout;
    try testing.expectError(error.LayoutCycle, value.validate());
}

test "workspace snapshot rejects shared layout children" {
    const testing = std.testing;

    var repeated_layout = fixture_layout;
    repeated_layout[1].child_ids = &.{ "leaf-1", "leaf-1" };
    var repeated = buildSnapshot();
    repeated.layout = &repeated_layout;
    try testing.expectError(
        error.LayoutNodeMultipleParents,
        repeated.validate(),
    );

    const diamond_layout = [_]snapshot.LayoutNodeRecord{
        .{
            .layout_node_id = "split-1-root",
            .node_type = .split_root,
            .child_ids = &.{"root-1"},
        },
        .{
            .layout_node_id = "root-1",
            .tab_id = ids.TabId.init(1),
            .node_type = .tab_root,
            .child_ids = &.{ "split-a", "split-b" },
        },
        .{
            .layout_node_id = "split-a",
            .tab_id = ids.TabId.init(1),
            .node_type = .split,
            .split_direction = .right,
            .child_ids = &.{"leaf-1"},
        },
        .{
            .layout_node_id = "split-b",
            .tab_id = ids.TabId.init(1),
            .node_type = .split,
            .split_direction = .down,
            .child_ids = &.{"leaf-1"},
        },
        .{
            .layout_node_id = "leaf-1",
            .tab_id = ids.TabId.init(1),
            .node_type = .session_leaf,
            .session_id = ids.SessionId.init(1),
        },
    };
    var diamond = buildSnapshot();
    diamond.layout = &diamond_layout;
    try testing.expectError(
        error.LayoutNodeMultipleParents,
        diamond.validate(),
    );
}

test "workspace snapshot validates persisted split ratios" {
    const testing = std.testing;
    const invalid_ratios = [_]f64{
        -0.01,
        1.01,
        std.math.nan(f64),
        std.math.inf(f64),
        -std.math.inf(f64),
    };
    for (invalid_ratios) |ratio| {
        const node: snapshot.LayoutNodeRecord = .{
            .layout_node_id = "split",
            .node_type = .split,
            .split_direction = .right,
            .ratio = ratio,
            .child_ids = &.{},
        };
        try testing.expectError(error.InvalidSplitRatio, node.validate());
    }

    for ([_]f64{ 0, 1 }) |ratio| {
        const node: snapshot.LayoutNodeRecord = .{
            .layout_node_id = "split",
            .node_type = .split,
            .split_direction = .right,
            .ratio = ratio,
            .child_ids = &.{},
        };
        try node.validate();
    }
}

test "workspace snapshot decode frees allocations when validation fails" {
    const testing = std.testing;

    const encoded = try buildSnapshot().encodeAlloc(testing.allocator);
    defer testing.allocator.free(encoded);
    const version = std.mem.indexOf(u8, encoded, "\"version\": 1") orelse
        return error.MissingFixtureVersion;
    encoded[version + "\"version\": ".len] = '0';

    try testing.expectError(
        error.InvalidSnapshotVersion,
        snapshot.Snapshot.decodeAlloc(testing.allocator, encoded),
    );
}

test "workspace snapshot round trips through storage" {
    const testing = std.testing;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const storage = storage_mod.Storage.init(testing.allocator, tmp.dir);
    const filename = try storage.writeSnapshot(buildSnapshot());
    defer testing.allocator.free(filename);

    const loaded = try storage.readSnapshotAlloc(testing.allocator, filename);
    defer loaded.deinit(testing.allocator);
    try testing.expectEqual(ids.SnapshotId.init(1), loaded.snapshot_id);
    try testing.expectEqual(ids.WorkspaceId.init(1), loaded.workspace.workspace_id);
    try testing.expectEqualStrings("workspace-key-1", loaded.workspace.workspace_key.?);
    try testing.expectEqualStrings("Developer Workspace", loaded.workspace.name);
    try testing.expectEqual(@as(usize, 1), loaded.splits.len);
    try testing.expectEqual(ids.SplitId.init(1), loaded.splits[0].split_id);
    try testing.expectEqual(ids.WindowId.init(1), loaded.splits[0].window_id.?);
    try testing.expectEqual(@as(usize, 3), loaded.layout.len);
    try testing.expectEqual(model.SnapshotNodeType.split_root, loaded.layout[0].node_type);
    try testing.expectEqual(model.SnapshotNodeType.tab_root, loaded.layout[1].node_type);
    try testing.expectEqualStrings("zig", loaded.sessions[0].command.argv[0]);
}

test "workspace catalog round trips through storage" {
    const testing = std.testing;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const storage = storage_mod.Storage.init(testing.allocator, tmp.dir);
    const expected_filename = try storage.checkpointFilenameAlloc("workspace-key-1");
    defer testing.allocator.free(expected_filename);
    const catalog: snapshot.Catalog = .{
        .entries = &.{.{
            .snapshot_id = ids.SnapshotId.init(1),
            .workspace_id = ids.WorkspaceId.init(1),
            .workspace_key = "workspace-key-1",
            .workspace_name = "Developer Workspace",
            .saved_at = "2026-03-22T12:00:00Z",
            .path = expected_filename,
        }},
    };

    try storage.writeCatalog(catalog, storage_mod.Storage.catalog_filename);

    const loaded = try storage.readCatalogAlloc(testing.allocator, storage_mod.Storage.catalog_filename);
    defer loaded.deinit(testing.allocator);

    try testing.expectEqual(@as(u32, 1), loaded.version);
    try testing.expectEqual(@as(usize, 1), loaded.entries.len);
    try testing.expectEqual(ids.WorkspaceId.init(1), loaded.entries[0].workspace_id);
    try testing.expectEqualStrings("workspace-key-1", loaded.entries[0].workspace_key.?);
    try testing.expectEqualStrings(expected_filename, loaded.entries[0].path);
}

test "workspace catalog rejects future versions" {
    const testing = std.testing;
    const encoded = try (snapshot.Catalog{ .version = 2 }).encodeAlloc(
        testing.allocator,
    );
    defer testing.allocator.free(encoded);

    try testing.expectError(
        error.InvalidSnapshotVersion,
        snapshot.Catalog.decodeAlloc(testing.allocator, encoded),
    );
}

test "workspace checkpoint updates latest catalog entry and prunes replaced snapshot" {
    const testing = std.testing;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const storage = storage_mod.Storage.init(testing.allocator, tmp.dir);
    const expected_filename = try storage.checkpointFilenameAlloc("workspace-key-1");
    defer testing.allocator.free(expected_filename);

    var first_snapshot = buildSnapshot();
    first_snapshot.saved_at = "2026-03-22T12:00:00Z";
    const first_filename = try storage.writeCheckpoint(first_snapshot);
    defer testing.allocator.free(first_filename);
    try testing.expectEqualStrings(expected_filename, first_filename);

    var second_snapshot = buildSnapshot();
    second_snapshot.snapshot_id = ids.SnapshotId.init(2);
    second_snapshot.saved_at = "2026-03-22T12:30:00Z";
    const second_filename = try storage.writeCheckpoint(second_snapshot);
    defer testing.allocator.free(second_filename);
    try testing.expectEqualStrings(expected_filename, second_filename);

    const loaded = try storage.readCatalogAlloc(testing.allocator, storage_mod.Storage.catalog_filename);
    defer loaded.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), loaded.entries.len);
    try testing.expectEqual(ids.SnapshotId.init(2), loaded.entries[0].snapshot_id);
    try testing.expectEqual(ids.WorkspaceId.init(1), loaded.entries[0].workspace_id);
    try testing.expectEqualStrings("workspace-key-1", loaded.entries[0].workspace_key.?);
    try testing.expectEqualStrings(expected_filename, loaded.entries[0].path);
    try testing.expectEqualStrings("2026-03-22T12:30:00Z", loaded.entries[0].saved_at);

    try tmp.dir.access(std.testing.io, expected_filename, .{});
}

test "workspace prune retries orphan artifact cleanup without catalog entry" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const storage = storage_mod.Storage.init(testing.allocator, tmp.dir);
    const checkpoint_path = try storage.checkpointFilenameAlloc("orphan-workspace");
    defer testing.allocator.free(checkpoint_path);
    const checkpoint = try tmp.dir.createFile(testing.io, checkpoint_path, .{});
    checkpoint.close(testing.io);
    try storage.ensureScrollbackDir(checkpoint_path);

    try storage.pruneCheckpoint("orphan-workspace");
    try testing.expectError(
        error.FileNotFound,
        tmp.dir.access(testing.io, checkpoint_path, .{}),
    );
    const scrollback_path = try std.fmt.allocPrint(
        testing.allocator,
        "{s}.scrollback",
        .{checkpoint_path},
    );
    defer testing.allocator.free(scrollback_path);
    try testing.expectError(
        error.FileNotFound,
        tmp.dir.openDir(testing.io, scrollback_path, .{}),
    );
}

test "workspace prune removes keyed and legacy entries atomically" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const storage = storage_mod.Storage.init(testing.allocator, tmp.dir);
    const workspace_key = "workspace-key";
    const keyed_path = try storage.checkpointFilenameAlloc(workspace_key);
    defer testing.allocator.free(keyed_path);
    const legacy_path = "legacy-deadbeef.json";
    const catalog: snapshot.Catalog = .{
        .entries = &.{
            .{
                .snapshot_id = ids.SnapshotId.init(1),
                .workspace_id = ids.WorkspaceId.init(1),
                .workspace_key = workspace_key,
                .workspace_name = "workspace",
                .saved_at = "2026-03-22T12:00:00Z",
                .path = keyed_path,
            },
            .{
                .snapshot_id = ids.SnapshotId.init(2),
                .workspace_id = ids.WorkspaceId.init(1),
                .workspace_name = "workspace",
                .saved_at = "2026-03-22T11:00:00Z",
                .path = legacy_path,
            },
        },
    };
    try storage.writeCatalog(catalog, storage_mod.Storage.catalog_filename);

    for ([_][]const u8{ keyed_path, legacy_path }) |path| {
        const file = try tmp.dir.createFile(testing.io, path, .{});
        file.close(testing.io);
        try storage.ensureScrollbackDir(path);
    }

    try storage.pruneCheckpointWithFallbackPath(workspace_key, legacy_path);
    const loaded = try storage.readCatalogAlloc(
        testing.allocator,
        storage_mod.Storage.catalog_filename,
    );
    defer loaded.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), loaded.entries.len);
    for ([_][]const u8{ keyed_path, legacy_path }) |path| {
        try testing.expectError(
            error.FileNotFound,
            tmp.dir.access(testing.io, path, .{}),
        );
    }
}

test "workspace keyed save migrates matching keyless catalog entry" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const storage = storage_mod.Storage.init(testing.allocator, tmp.dir);
    const legacy_path = "legacy-deadbeef.json";
    const existing_keyed_path = try storage.checkpointFilenameAlloc(
        "workspace-key-1",
    );
    defer testing.allocator.free(existing_keyed_path);
    const catalog: snapshot.Catalog = .{
        .entries = &.{
            .{
                .snapshot_id = ids.SnapshotId.init(8),
                .workspace_id = ids.WorkspaceId.init(8),
                .workspace_key = "workspace-key-1",
                .workspace_name = "Developer Workspace",
                .saved_at = "2026-03-22T10:00:00Z",
                .path = existing_keyed_path,
            },
            .{
                .snapshot_id = ids.SnapshotId.init(9),
                .workspace_id = ids.WorkspaceId.init(99),
                .workspace_name = "Developer Workspace",
                .saved_at = "2026-03-22T11:00:00Z",
                .path = legacy_path,
            },
        },
    };
    try storage.writeCatalog(catalog, storage_mod.Storage.catalog_filename);
    const legacy_file = try tmp.dir.createFile(testing.io, legacy_path, .{});
    legacy_file.close(testing.io);
    try storage.ensureScrollbackDir(legacy_path);

    var transaction = try storage.beginTransaction(.blocking);
    defer transaction.deinit();
    var commit_state: storage_mod.Storage.CheckpointCommitState = .uncommitted;
    const keyed_path = try storage.writeCheckpointTrackedReplacingPathAssumeLocked(
        buildSnapshot(),
        legacy_path,
        &commit_state,
    );
    defer testing.allocator.free(keyed_path);
    const loaded = try storage.readCatalogAlloc(
        testing.allocator,
        storage_mod.Storage.catalog_filename,
    );
    defer loaded.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), loaded.entries.len);
    try testing.expectEqualStrings(
        "workspace-key-1",
        loaded.entries[0].workspace_key.?,
    );
    try testing.expectEqualStrings(keyed_path, loaded.entries[0].path);
    try testing.expectError(
        error.FileNotFound,
        tmp.dir.access(testing.io, legacy_path, .{}),
    );
}

test "workspace storage caps catalog and snapshot json reads and writes" {
    const testing = std.testing;

    {
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();

        const storage = storage_mod.Storage.init(testing.allocator, tmp.dir);
        {
            const file = try tmp.dir.createFile(std.testing.io, storage_mod.Storage.catalog_filename, .{});
            defer file.close(std.testing.io);
            try file.setLength(std.testing.io, storage_mod.Storage.max_catalog_json_bytes + 1);
        }
        try testing.expectError(
            error.FileTooBig,
            storage.readCatalogAlloc(testing.allocator, storage_mod.Storage.catalog_filename),
        );

        const snapshot_filename = try storage.checkpointFilenameAlloc("workspace-key-1");
        defer testing.allocator.free(snapshot_filename);
        {
            const file = try tmp.dir.createFile(std.testing.io, snapshot_filename, .{});
            defer file.close(std.testing.io);
            try file.setLength(std.testing.io, storage_mod.Storage.max_snapshot_json_bytes + 1);
        }
        try testing.expectError(
            error.FileTooBig,
            storage.readSnapshotAlloc(testing.allocator, snapshot_filename),
        );
    }

    {
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();

        const storage = storage_mod.Storage.init(testing.allocator, tmp.dir);
        const huge_name = try testing.allocator.alloc(u8, storage_mod.Storage.max_catalog_json_bytes + 1);
        defer testing.allocator.free(huge_name);
        @memset(huge_name, 'a');
        const catalog: snapshot.Catalog = .{
            .entries = &.{.{
                .snapshot_id = ids.SnapshotId.init(1),
                .workspace_id = ids.WorkspaceId.init(1),
                .workspace_key = "workspace-key-1",
                .workspace_name = huge_name,
                .saved_at = "2026-03-22T12:00:00Z",
                .path = "workspace-key-1-deadbeef.json",
            }},
        };
        try testing.expectError(
            error.FileTooBig,
            storage.writeCatalog(catalog, storage_mod.Storage.catalog_filename),
        );
        try testing.expectError(
            error.FileNotFound,
            tmp.dir.access(std.testing.io, storage_mod.Storage.catalog_filename, .{}),
        );
    }

    {
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();

        const storage = storage_mod.Storage.init(testing.allocator, tmp.dir);
        const huge_name = try testing.allocator.alloc(u8, storage_mod.Storage.max_snapshot_json_bytes + 1);
        defer testing.allocator.free(huge_name);
        @memset(huge_name, 'b');
        var value = buildSnapshot();
        value.workspace.name = huge_name;

        try testing.expectError(error.FileTooBig, storage.writeSnapshot(value));
        const snapshot_filename = try storage.checkpointFilenameAlloc("workspace-key-1");
        defer testing.allocator.free(snapshot_filename);
        try testing.expectError(error.FileNotFound, tmp.dir.access(std.testing.io, snapshot_filename, .{}));
    }
}

test "workspace storage reads json files without following symlinks" {
    const testing = std.testing;
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const storage = storage_mod.Storage.init(testing.allocator, tmp.dir);
    {
        const file = try tmp.dir.createFile(std.testing.io, "target.json", .{});
        defer file.close(std.testing.io);
        try file.writeStreamingAll(std.testing.io, "{}");
    }

    try tmp.dir.symLink(std.testing.io, "target.json", storage_mod.Storage.catalog_filename, .{});
    try testing.expectError(
        error.SymLinkLoop,
        storage.readCatalogAlloc(testing.allocator, storage_mod.Storage.catalog_filename),
    );
    try testing.expectError(error.SymLinkLoop, storage.writeCheckpoint(buildSnapshot()));

    var tmp_snapshot = testing.tmpDir(.{});
    defer tmp_snapshot.cleanup();

    const snapshot_storage = storage_mod.Storage.init(testing.allocator, tmp_snapshot.dir);
    {
        const file = try tmp_snapshot.dir.createFile(std.testing.io, "target.json", .{});
        defer file.close(std.testing.io);
        try file.writeStreamingAll(std.testing.io, "{}");
    }
    const snapshot_filename = try snapshot_storage.checkpointFilenameAlloc("workspace-key-1");
    defer testing.allocator.free(snapshot_filename);
    try tmp_snapshot.dir.symLink(std.testing.io, "target.json", snapshot_filename, .{});
    try testing.expectError(
        error.SymLinkLoop,
        snapshot_storage.readSnapshotAlloc(testing.allocator, snapshot_filename),
    );
}

test "workspace checkpoint save preserves oversized or malformed catalog" {
    const testing = std.testing;

    {
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();

        const storage = storage_mod.Storage.init(testing.allocator, tmp.dir);
        const snapshot_filename = try storage.checkpointFilenameAlloc("workspace-key-1");
        defer testing.allocator.free(snapshot_filename);
        {
            const file = try tmp.dir.createFile(std.testing.io, snapshot_filename, .{});
            defer file.close(std.testing.io);
            try file.writeStreamingAll(std.testing.io, "old snapshot");
        }
        {
            const file = try tmp.dir.createFile(std.testing.io, storage_mod.Storage.catalog_filename, .{});
            defer file.close(std.testing.io);
            try file.setLength(std.testing.io, storage_mod.Storage.max_catalog_json_bytes + 1);
        }

        try testing.expectError(error.FileTooBig, storage.writeCheckpoint(buildSnapshot()));
        const stat = try tmp.dir.statFile(
            std.testing.io,
            storage_mod.Storage.catalog_filename,
            .{},
        );
        try testing.expectEqual(
            @as(u64, storage_mod.Storage.max_catalog_json_bytes + 1),
            stat.size,
        );
        const snapshot_data = try tmp.dir.readFileAlloc(
            std.testing.io,
            snapshot_filename,
            testing.allocator,
            .limited(1024),
        );
        defer testing.allocator.free(snapshot_data);
        try testing.expectEqualStrings("old snapshot", snapshot_data);
    }

    {
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();

        const storage = storage_mod.Storage.init(testing.allocator, tmp.dir);
        const snapshot_filename = try storage.checkpointFilenameAlloc("workspace-key-1");
        defer testing.allocator.free(snapshot_filename);
        {
            const file = try tmp.dir.createFile(std.testing.io, snapshot_filename, .{});
            defer file.close(std.testing.io);
            try file.writeStreamingAll(std.testing.io, "old snapshot");
        }
        {
            const file = try tmp.dir.createFile(std.testing.io, storage_mod.Storage.catalog_filename, .{});
            defer file.close(std.testing.io);
            try file.writeStreamingAll(std.testing.io, "{not-json");
        }

        if (storage.writeCheckpoint(buildSnapshot())) |filename| {
            defer testing.allocator.free(filename);
            return error.ExpectedCatalogWriteFailure;
        } else |_| {}

        const data = try tmp.dir.readFileAlloc(
            std.testing.io,
            storage_mod.Storage.catalog_filename,
            testing.allocator,
            .limited(1024),
        );
        defer testing.allocator.free(data);
        try testing.expectEqualStrings("{not-json", data);
        const snapshot_data = try tmp.dir.readFileAlloc(
            std.testing.io,
            snapshot_filename,
            testing.allocator,
            .limited(1024),
        );
        defer testing.allocator.free(snapshot_data);
        try testing.expectEqualStrings("old snapshot", snapshot_data);
    }
}

test "workspace checkpoint tracks successful rollback after catalog write failure" {
    const testing = std.testing;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const storage = storage_mod.Storage.init(testing.allocator, tmp.dir);
    const snapshot_filename = try storage.checkpointFilenameAlloc("workspace-key-1");
    defer testing.allocator.free(snapshot_filename);
    {
        const file = try tmp.dir.createFile(std.testing.io, snapshot_filename, .{});
        defer file.close(std.testing.io);
        try file.writeStreamingAll(std.testing.io, "old snapshot");
    }

    const base_entry: snapshot.CatalogEntry = .{
        .snapshot_id = ids.SnapshotId.init(1),
        .workspace_id = ids.WorkspaceId.init(2),
        .workspace_key = "other-workspace",
        .workspace_name = "",
        .saved_at = "2026-07-10T00:00:00Z",
        .path = "other-workspace-deadbeef.json",
    };
    const base_catalog: snapshot.Catalog = .{
        .entries = &.{base_entry},
    };
    const base_data = try base_catalog.encodeAlloc(testing.allocator);
    defer testing.allocator.free(base_data);
    const large_name = try testing.allocator.alloc(
        u8,
        storage_mod.Storage.max_catalog_json_bytes - base_data.len,
    );
    defer testing.allocator.free(large_name);
    @memset(large_name, 'x');

    const full_catalog: snapshot.Catalog = .{
        .entries = &.{.{
            .snapshot_id = base_entry.snapshot_id,
            .workspace_id = base_entry.workspace_id,
            .workspace_key = base_entry.workspace_key,
            .workspace_name = large_name,
            .saved_at = base_entry.saved_at,
            .path = base_entry.path,
        }},
    };
    try storage.writeCatalog(
        full_catalog,
        storage_mod.Storage.catalog_filename,
    );

    var transaction = try storage.beginTransaction(.blocking);
    defer transaction.deinit();
    var commit_state: storage_mod.Storage.CheckpointCommitState = .committed;
    try testing.expectError(
        error.FileTooBig,
        storage.writeCheckpointTrackedAssumeLocked(
            buildSnapshot(),
            &commit_state,
        ),
    );
    try testing.expectEqual(
        storage_mod.Storage.CheckpointCommitState.uncommitted,
        commit_state,
    );

    const snapshot_data = try tmp.dir.readFileAlloc(
        std.testing.io,
        snapshot_filename,
        testing.allocator,
        .limited(1024),
    );
    defer testing.allocator.free(snapshot_data);
    try testing.expectEqualStrings("old snapshot", snapshot_data);

    const restored_catalog = try storage.readCatalogAlloc(
        testing.allocator,
        storage_mod.Storage.catalog_filename,
    );
    defer restored_catalog.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), restored_catalog.entries.len);
    try testing.expectEqual(
        large_name.len,
        restored_catalog.entries[0].workspace_name.len,
    );
}

test "workspace storage atomic writes ignore stale deterministic temp symlinks" {
    const testing = std.testing;
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const storage = storage_mod.Storage.init(testing.allocator, tmp.dir);
    {
        const file = try tmp.dir.createFile(std.testing.io, "target", .{});
        defer file.close(std.testing.io);
        try file.writeStreamingAll(std.testing.io, "keep");
    }
    try tmp.dir.symLink(std.testing.io, "target", "catalog.json.tmp", .{});

    try storage.writeCatalog(.{}, storage_mod.Storage.catalog_filename);

    const target = try tmp.dir.readFileAlloc(
        std.testing.io,
        "target",
        testing.allocator,
        .limited(1024),
    );
    defer testing.allocator.free(target);
    try testing.expectEqualStrings("keep", target);
}

test "workspace checkpoint pruning ignores unsafe catalog cleanup paths" {
    const testing = std.testing;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    defer tmp.parent_dir.deleteTree(std.testing.io, "outside.scrollback") catch {};

    const storage = storage_mod.Storage.init(testing.allocator, tmp.dir);
    const catalog: snapshot.Catalog = .{
        .entries = &.{.{
            .snapshot_id = ids.SnapshotId.init(1),
            .workspace_id = ids.WorkspaceId.init(1),
            .workspace_key = "workspace-key-1",
            .workspace_name = "Developer Workspace",
            .saved_at = "2026-03-22T12:00:00Z",
            .path = "../outside",
        }},
    };

    try tmp.parent_dir.createDirPath(std.testing.io, "outside.scrollback");
    try storage.writeCatalog(catalog, storage_mod.Storage.catalog_filename);
    try storage.pruneCheckpoint("workspace-key-1");

    try tmp.parent_dir.access(std.testing.io, "outside.scrollback", .{});
    const loaded = try storage.readCatalogAlloc(testing.allocator, storage_mod.Storage.catalog_filename);
    defer loaded.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), loaded.entries.len);
}

test "workspace checkpoint pruning never deletes catalog from poisoned catalog path" {
    const testing = std.testing;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const storage = storage_mod.Storage.init(testing.allocator, tmp.dir);
    const catalog: snapshot.Catalog = .{
        .entries = &.{.{
            .snapshot_id = ids.SnapshotId.init(1),
            .workspace_id = ids.WorkspaceId.init(1),
            .workspace_key = "workspace-key-1",
            .workspace_name = "Developer Workspace",
            .saved_at = "2026-03-22T12:00:00Z",
            .path = storage_mod.Storage.catalog_filename,
        }},
    };

    try storage.writeCatalog(catalog, storage_mod.Storage.catalog_filename);
    try storage.pruneCheckpoint("workspace-key-1");

    const loaded = try storage.readCatalogAlloc(testing.allocator, storage_mod.Storage.catalog_filename);
    defer loaded.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), loaded.entries.len);
}

test "workspace checkpoint replacement never deletes catalog from poisoned catalog path" {
    const testing = std.testing;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const storage = storage_mod.Storage.init(testing.allocator, tmp.dir);
    const expected_filename = try storage.checkpointFilenameAlloc("workspace-key-1");
    defer testing.allocator.free(expected_filename);
    const catalog: snapshot.Catalog = .{
        .entries = &.{.{
            .snapshot_id = ids.SnapshotId.init(1),
            .workspace_id = ids.WorkspaceId.init(1),
            .workspace_key = "workspace-key-1",
            .workspace_name = "Developer Workspace",
            .saved_at = "2026-03-22T12:00:00Z",
            .path = storage_mod.Storage.catalog_filename,
        }},
    };

    try storage.writeCatalog(catalog, storage_mod.Storage.catalog_filename);
    const filename = try storage.writeCheckpoint(buildSnapshot());
    defer testing.allocator.free(filename);
    try testing.expectEqualStrings(expected_filename, filename);

    const loaded = try storage.readCatalogAlloc(testing.allocator, storage_mod.Storage.catalog_filename);
    defer loaded.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), loaded.entries.len);
    try testing.expectEqualStrings(expected_filename, loaded.entries[0].path);
}

test "workspace checkpoint path pruning removes keyless valid checkpoint artifacts" {
    const testing = std.testing;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const storage = storage_mod.Storage.init(testing.allocator, tmp.dir);
    const checkpoint_path = try storage.checkpointFilenameAlloc("legacy-key");
    defer testing.allocator.free(checkpoint_path);
    const catalog: snapshot.Catalog = .{
        .entries = &.{.{
            .snapshot_id = ids.SnapshotId.init(1),
            .workspace_id = ids.WorkspaceId.init(1),
            .workspace_key = null,
            .workspace_name = "Legacy Workspace",
            .saved_at = "2026-03-22T12:00:00Z",
            .path = checkpoint_path,
        }},
    };

    {
        const file = try tmp.dir.createFile(std.testing.io, checkpoint_path, .{});
        defer file.close(std.testing.io);
        try file.writeStreamingAll(std.testing.io, "{}");
    }
    try storage.ensureScrollbackDir(checkpoint_path);
    try storage.writeCatalog(catalog, storage_mod.Storage.catalog_filename);

    try storage.pruneCheckpointPath(checkpoint_path);

    try testing.expectError(error.FileNotFound, tmp.dir.access(std.testing.io, checkpoint_path, .{}));
    const sidecar_dir = try storage.scrollbackDirnameAlloc(checkpoint_path);
    defer testing.allocator.free(sidecar_dir);
    try testing.expectError(error.FileNotFound, tmp.dir.access(std.testing.io, sidecar_dir, .{}));
    const loaded = try storage.readCatalogAlloc(testing.allocator, storage_mod.Storage.catalog_filename);
    defer loaded.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), loaded.entries.len);
}

test "workspace checkpoint path pruning preserves legacy cleanup when sidecar is absent" {
    const testing = std.testing;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const storage = storage_mod.Storage.init(testing.allocator, tmp.dir);
    const checkpoint_path = try storage.checkpointFilenameAlloc("legacy-key");
    defer testing.allocator.free(checkpoint_path);
    const catalog: snapshot.Catalog = .{
        .entries = &.{.{
            .snapshot_id = ids.SnapshotId.init(1),
            .workspace_id = ids.WorkspaceId.init(1),
            .workspace_key = null,
            .workspace_name = "Legacy Workspace",
            .saved_at = "2026-03-22T12:00:00Z",
            .path = checkpoint_path,
        }},
    };

    {
        const file = try tmp.dir.createFile(std.testing.io, checkpoint_path, .{});
        defer file.close(std.testing.io);
        try file.writeStreamingAll(std.testing.io, "{}");
    }
    try storage.writeCatalog(catalog, storage_mod.Storage.catalog_filename);

    try storage.pruneCheckpointPath(checkpoint_path);

    try testing.expectError(error.FileNotFound, tmp.dir.access(std.testing.io, checkpoint_path, .{}));
    const loaded = try storage.readCatalogAlloc(testing.allocator, storage_mod.Storage.catalog_filename);
    defer loaded.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), loaded.entries.len);
}

test "workspace scrollback sidecar helpers reject unsafe checkpoint paths" {
    const testing = std.testing;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const storage = storage_mod.Storage.init(testing.allocator, tmp.dir);
    const checkpoint_path = try storage.checkpointFilenameAlloc("workspace-key-1");
    defer testing.allocator.free(checkpoint_path);
    const valid_sidecar_path = try storage.scrollbackFilenameAlloc(
        checkpoint_path,
        ids.SnapshotId.init(1),
        ids.SessionId.init(1),
    );
    defer testing.allocator.free(valid_sidecar_path);

    try testing.expect(storage_mod.Storage.validScrollbackSidecarPath(valid_sidecar_path));
    try testing.expect(storage_mod.Storage.validScrollbackSidecarPathForCheckpoint(
        valid_sidecar_path,
        checkpoint_path,
    ));
    try testing.expect(storage_mod.Storage.validScrollbackSidecarPathForCheckpointAndSession(
        valid_sidecar_path,
        checkpoint_path,
        ids.SessionId.init(1),
    ));
    try testing.expect(!storage_mod.Storage.validScrollbackSidecarPathForCheckpointAndSession(
        valid_sidecar_path,
        checkpoint_path,
        ids.SessionId.init(2),
    ));
    try testing.expect(!storage_mod.Storage.validScrollbackSidecarPathForCheckpoint(
        valid_sidecar_path,
        "other-deadbeef.json",
    ));
    try testing.expect(!storage_mod.Storage.validScrollbackSidecarPath(storage_mod.Storage.catalog_filename));
    try testing.expect(!storage_mod.Storage.validScrollbackSidecarPath("workspace-key-1-deadbeef.json"));
    try testing.expect(!storage_mod.Storage.validScrollbackSidecarPath("workspace-key-1-deadbeef.json.scrollback/session-1.vt"));
    try testing.expect(!storage_mod.Storage.validScrollbackSidecarPath("workspace-key-1-deadbeef.json.scrollback/snapshot-1/session-1.vt\x00truncated"));

    try testing.expectError(error.InvalidCheckpointPath, storage.deleteScrollbackDir("../outside"));
    try testing.expectError(error.InvalidCheckpointPath, storage.deleteScrollbackDir(storage_mod.Storage.catalog_filename));
    try testing.expectError(error.InvalidCheckpointPath, storage.ensureScrollbackDir("nested/path.json"));
    try testing.expectError(
        error.InvalidCheckpointPath,
        storage.ensureScrollbackDirForSnapshot("nested/path.json", ids.SnapshotId.init(1)),
    );
    try testing.expectError(error.InvalidCheckpointPath, storage.ensureScrollbackDir("nested\\path.json"));
    try testing.expectError(
        error.InvalidCheckpointPath,
        storage.scrollbackFilenameAlloc("nested\\path.json", ids.SnapshotId.init(1), ids.SessionId.init(1)),
    );
}

test "workspace checkpoint filenames include a hash to avoid sanitized collisions" {
    const testing = std.testing;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const storage = storage_mod.Storage.init(testing.allocator, tmp.dir);
    const slash = try storage.checkpointFilenameAlloc("a/b");
    defer testing.allocator.free(slash);
    const underscore = try storage.checkpointFilenameAlloc("a_b");
    defer testing.allocator.free(underscore);

    try testing.expect(!std.mem.eql(u8, slash, underscore));
}

test "workspace storage rejects snapshots with invalid scrollback sidecar paths" {
    const testing = std.testing;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const storage = storage_mod.Storage.init(testing.allocator, tmp.dir);
    var value = buildSnapshot();
    var sessions = [_]snapshot.SessionRecord{fixture_sessions[0]};
    sessions[0].scrollback_path = "workspace-key-1-deadbeef.json.scrollback/session-1.vt";
    value.sessions = &sessions;

    try testing.expectError(error.InvalidWorkspaceScrollbackPath, storage.writeSnapshot(value));
}

test "workspace storage rejects scrollback sidecars for another checkpoint" {
    const testing = std.testing;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const storage = storage_mod.Storage.init(testing.allocator, tmp.dir);
    const other_checkpoint_path = try storage.checkpointFilenameAlloc("other-workspace");
    defer testing.allocator.free(other_checkpoint_path);
    const other_sidecar_path = try storage.scrollbackFilenameAlloc(
        other_checkpoint_path,
        ids.SnapshotId.init(1),
        ids.SessionId.init(1),
    );
    defer testing.allocator.free(other_sidecar_path);

    var value = buildSnapshot();
    var sessions = [_]snapshot.SessionRecord{fixture_sessions[0]};
    sessions[0].scrollback_path = other_sidecar_path;
    value.sessions = &sessions;

    try testing.expect(storage_mod.Storage.validScrollbackSidecarPath(other_sidecar_path));
    try testing.expectError(error.InvalidWorkspaceScrollbackPath, storage.writeSnapshot(value));
}

test "workspace storage rejects scrollback sidecars for another session" {
    const testing = std.testing;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const storage = storage_mod.Storage.init(testing.allocator, tmp.dir);
    const checkpoint_path = try storage.checkpointFilenameAlloc("workspace-key-1");
    defer testing.allocator.free(checkpoint_path);
    const other_session_sidecar_path = try storage.scrollbackFilenameAlloc(
        checkpoint_path,
        ids.SnapshotId.init(1),
        ids.SessionId.init(2),
    );
    defer testing.allocator.free(other_session_sidecar_path);

    var value = buildSnapshot();
    var sessions = [_]snapshot.SessionRecord{fixture_sessions[0]};
    sessions[0].scrollback_path = other_session_sidecar_path;
    value.sessions = &sessions;

    try testing.expect(storage_mod.Storage.validScrollbackSidecarPathForCheckpoint(
        other_session_sidecar_path,
        checkpoint_path,
    ));
    try testing.expectError(error.InvalidWorkspaceScrollbackPath, storage.writeSnapshot(value));
}

test "workspace storage rejects persisted snapshots with invalid scrollback sidecar paths" {
    const testing = std.testing;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const storage = storage_mod.Storage.init(testing.allocator, tmp.dir);
    var value = buildSnapshot();
    var sessions = [_]snapshot.SessionRecord{fixture_sessions[0]};
    sessions[0].scrollback_path = "workspace-key-1-deadbeef.json.scrollback/session-1.vt";
    value.sessions = &sessions;

    const encoded = try value.encodeAlloc(testing.allocator);
    defer testing.allocator.free(encoded);
    const file = try tmp.dir.createFile(std.testing.io, "workspace-key-1-deadbeef.json", .{});
    defer file.close(std.testing.io);
    try file.writeStreamingAll(std.testing.io, encoded);

    try testing.expectError(
        error.InvalidWorkspaceScrollbackPath,
        storage.readSnapshotAlloc(testing.allocator, "workspace-key-1-deadbeef.json"),
    );
}

test "workspace storage rejects persisted scrollback sidecars for another session" {
    const testing = std.testing;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const storage = storage_mod.Storage.init(testing.allocator, tmp.dir);
    const checkpoint_path = try storage.checkpointFilenameAlloc("workspace-key-1");
    defer testing.allocator.free(checkpoint_path);
    const other_session_sidecar_path = try storage.scrollbackFilenameAlloc(
        checkpoint_path,
        ids.SnapshotId.init(1),
        ids.SessionId.init(2),
    );
    defer testing.allocator.free(other_session_sidecar_path);

    var value = buildSnapshot();
    var sessions = [_]snapshot.SessionRecord{fixture_sessions[0]};
    sessions[0].scrollback_path = other_session_sidecar_path;
    value.sessions = &sessions;

    const encoded = try value.encodeAlloc(testing.allocator);
    defer testing.allocator.free(encoded);
    const file = try tmp.dir.createFile(std.testing.io, checkpoint_path, .{});
    defer file.close(std.testing.io);
    try file.writeStreamingAll(std.testing.io, encoded);

    try testing.expectError(
        error.InvalidWorkspaceScrollbackPath,
        storage.readSnapshotAlloc(testing.allocator, checkpoint_path),
    );
}

test "workspace storage resets scrollback sidecar directory" {
    const testing = std.testing;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const storage = storage_mod.Storage.init(testing.allocator, tmp.dir);
    const checkpoint_path = try storage.checkpointFilenameAlloc("workspace-key-1");
    defer testing.allocator.free(checkpoint_path);
    const snapshot_id = ids.SnapshotId.init(1);
    const scrollback_path = try storage.scrollbackFilenameAlloc(
        checkpoint_path,
        snapshot_id,
        ids.SessionId.init(7),
    );
    defer testing.allocator.free(scrollback_path);

    try storage.resetScrollbackDir(checkpoint_path);
    try storage.ensureScrollbackDirForSnapshot(checkpoint_path, snapshot_id);
    {
        const file = try tmp.dir.createFile(std.testing.io, scrollback_path, .{});
        defer file.close(std.testing.io);
        try file.writeStreamingAll(std.testing.io, "saved scrollback");
    }
    try tmp.dir.access(std.testing.io, scrollback_path, .{});

    try storage.resetScrollbackDir(checkpoint_path);
    try testing.expectError(error.FileNotFound, tmp.dir.access(std.testing.io, scrollback_path, .{}));
}

test "workspace storage ensures scrollback sidecar directory without pruning" {
    const testing = std.testing;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const storage = storage_mod.Storage.init(testing.allocator, tmp.dir);
    const checkpoint_path = try storage.checkpointFilenameAlloc("workspace-key-1");
    defer testing.allocator.free(checkpoint_path);
    const snapshot_id = ids.SnapshotId.init(1);
    const scrollback_path = try storage.scrollbackFilenameAlloc(
        checkpoint_path,
        snapshot_id,
        ids.SessionId.init(7),
    );
    defer testing.allocator.free(scrollback_path);

    try storage.ensureScrollbackDir(checkpoint_path);
    try storage.ensureScrollbackDirForSnapshot(checkpoint_path, snapshot_id);
    {
        const file = try tmp.dir.createFile(std.testing.io, scrollback_path, .{});
        defer file.close(std.testing.io);
        try file.writeStreamingAll(std.testing.io, "saved scrollback");
    }

    try storage.ensureScrollbackDir(checkpoint_path);
    try tmp.dir.access(std.testing.io, scrollback_path, .{});
}

test "workspace storage snapshot staging directories are exclusive" {
    const testing = std.testing;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const storage = storage_mod.Storage.init(testing.allocator, tmp.dir);
    const checkpoint_path = try storage.checkpointFilenameAlloc("workspace-key-1");
    defer testing.allocator.free(checkpoint_path);
    const snapshot_id = ids.SnapshotId.init(1);

    try storage.ensureScrollbackDir(checkpoint_path);
    try storage.createScrollbackDirForSnapshotExclusive(
        checkpoint_path,
        snapshot_id,
    );

    const marker_path = try storage.scrollbackFilenameAlloc(
        checkpoint_path,
        snapshot_id,
        ids.SessionId.init(1),
    );
    defer testing.allocator.free(marker_path);
    {
        const marker = try tmp.dir.createFile(std.testing.io, marker_path, .{});
        defer marker.close(std.testing.io);
        try marker.writeStreamingAll(std.testing.io, "committed");
    }

    try testing.expectError(
        error.PathAlreadyExists,
        storage.createScrollbackDirForSnapshotExclusive(
            checkpoint_path,
            snapshot_id,
        ),
    );
    const marker = try tmp.dir.readFileAlloc(
        std.testing.io,
        marker_path,
        testing.allocator,
        .limited(1024),
    );
    defer testing.allocator.free(marker);
    try testing.expectEqualStrings("committed", marker);
}

test "workspace storage transaction lock excludes concurrent writers" {
    const testing = std.testing;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const storage = storage_mod.Storage.init(testing.allocator, tmp.dir);
    var first = try storage.beginTransaction(.blocking);
    defer first.deinit();

    try testing.expectError(
        error.WorkspaceStorageBusy,
        storage.beginTransaction(.nonblocking),
    );
}

test "workspace storage opens scrollback sidecars without following symlinks" {
    const testing = std.testing;
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const storage = storage_mod.Storage.init(testing.allocator, tmp.dir);
    const checkpoint_path = try storage.checkpointFilenameAlloc("workspace-key-1");
    defer testing.allocator.free(checkpoint_path);
    const snapshot_id = ids.SnapshotId.init(1);
    const scrollback_path = try storage.scrollbackFilenameAlloc(
        checkpoint_path,
        snapshot_id,
        ids.SessionId.init(7),
    );
    defer testing.allocator.free(scrollback_path);

    try storage.ensureScrollbackDirForSnapshot(checkpoint_path, snapshot_id);
    {
        const file = try tmp.dir.createFile(std.testing.io, scrollback_path, .{});
        defer file.close(std.testing.io);
        try file.writeStreamingAll(std.testing.io, "saved scrollback");
    }
    {
        const file = try storage.openScrollbackFileRead(scrollback_path);
        defer file.close(std.testing.io);
    }

    try tmp.dir.deleteFile(std.testing.io, scrollback_path);
    try tmp.dir.symLink(std.testing.io, "target.vt", scrollback_path, .{});
    try testing.expectError(error.SymLinkLoop, storage.openScrollbackFileRead(scrollback_path));
    try tmp.dir.deleteFile(std.testing.io, scrollback_path);

    const sidecar_dir = try storage.scrollbackDirnameAlloc(checkpoint_path);
    defer testing.allocator.free(sidecar_dir);
    try tmp.dir.deleteTree(std.testing.io, sidecar_dir);
    try tmp.dir.createDirPath(std.testing.io, "outside");
    try tmp.dir.symLink(std.testing.io, "outside", sidecar_dir, .{ .is_directory = true });
    storage.ensureScrollbackDirForSnapshot(checkpoint_path, snapshot_id) catch |err| {
        try testing.expect(err == error.SymLinkLoop or err == error.NotDir);
        try testing.expectError(error.FileNotFound, tmp.dir.access(std.testing.io, "outside/snapshot-1", .{}));
        return;
    };
    return error.ExpectedSymlinkRejection;
}

test "workspace restore keeps opened scrollback stable after pruning" {
    const testing = std.testing;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const storage = storage_mod.Storage.init(testing.allocator, tmp.dir);
    const checkpoint_path = try storage.checkpointFilenameAlloc("workspace-key-1");
    defer testing.allocator.free(checkpoint_path);
    const scrollback_path = try storage.scrollbackFilenameAlloc(
        checkpoint_path,
        ids.SnapshotId.init(1),
        ids.SessionId.init(1),
    );
    defer testing.allocator.free(scrollback_path);

    try storage.ensureScrollbackDirForSnapshot(checkpoint_path, ids.SnapshotId.init(1));
    {
        const file = try tmp.dir.createFile(testing.io, scrollback_path, .{});
        defer file.close(testing.io);
        try file.writeStreamingAll(testing.io, "stable restore history");
    }

    var sessions = fixture_sessions;
    sessions[0].scrollback_path = scrollback_path;
    var value = buildSnapshot();
    value.sessions = &sessions;
    const written_path = try storage.writeSnapshot(value);
    defer testing.allocator.free(written_path);

    var transaction = try storage.beginTransaction(.blocking);
    var opened = try storage.readSnapshotWithScrollbackAllocAssumeLocked(
        testing.allocator,
        checkpoint_path,
        1024,
    );
    transaction.deinit();
    defer opened.deinit(testing.allocator);

    const file = opened.takeScrollbackFile(scrollback_path) orelse
        return error.ExpectedOpenedScrollback;
    defer file.close(testing.io);
    try tmp.dir.deleteFile(testing.io, scrollback_path);

    var buf: [64]u8 = undefined;
    const count = try file.readStreaming(testing.io, &.{&buf});
    try testing.expectEqualStrings("stable restore history", buf[0..count]);
}

test "workspace storage copies scrollback sidecars into snapshot dirs" {
    const testing = std.testing;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const storage = storage_mod.Storage.init(testing.allocator, tmp.dir);
    const checkpoint_path = try storage.checkpointFilenameAlloc("workspace-key-1");
    defer testing.allocator.free(checkpoint_path);
    const source_path = try storage.scrollbackFilenameAlloc(
        checkpoint_path,
        ids.SnapshotId.init(1),
        ids.SessionId.init(43),
    );
    defer testing.allocator.free(source_path);
    const dest_path = try storage.scrollbackFilenameAlloc(
        checkpoint_path,
        ids.SnapshotId.init(2),
        ids.SessionId.init(99),
    );
    defer testing.allocator.free(dest_path);

    try storage.ensureScrollbackDirForSnapshot(checkpoint_path, ids.SnapshotId.init(1));
    try storage.ensureScrollbackDirForSnapshot(checkpoint_path, ids.SnapshotId.init(2));
    {
        const file = try tmp.dir.createFile(std.testing.io, source_path, .{});
        defer file.close(std.testing.io);
        try file.writeStreamingAll(std.testing.io, "restored saved scrollback");
    }

    var dest_dir = try storage.openScrollbackDirForSnapshot(
        checkpoint_path,
        ids.SnapshotId.init(2),
    );
    defer dest_dir.close(std.testing.io);
    const copied_bytes = try storage.copyScrollbackFileToDir(
        source_path,
        dest_dir,
        std.fs.path.basename(dest_path),
        1024,
    );
    try testing.expectEqual(@as(u64, "restored saved scrollback".len), copied_bytes);

    const copied = try tmp.dir.readFileAlloc(
        std.testing.io,
        dest_path,
        testing.allocator,
        .limited(1024),
    );
    defer testing.allocator.free(copied);
    try testing.expectEqualStrings("restored saved scrollback", copied);
}

test "workspace storage rejects oversized scrollback sidecar copies" {
    const testing = std.testing;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const storage = storage_mod.Storage.init(testing.allocator, tmp.dir);
    const checkpoint_path = try storage.checkpointFilenameAlloc("workspace-key-1");
    defer testing.allocator.free(checkpoint_path);
    const source_path = try storage.scrollbackFilenameAlloc(
        checkpoint_path,
        ids.SnapshotId.init(1),
        ids.SessionId.init(43),
    );
    defer testing.allocator.free(source_path);
    const dest_path = try storage.scrollbackFilenameAlloc(
        checkpoint_path,
        ids.SnapshotId.init(2),
        ids.SessionId.init(99),
    );
    defer testing.allocator.free(dest_path);

    try storage.ensureScrollbackDirForSnapshot(checkpoint_path, ids.SnapshotId.init(1));
    try storage.ensureScrollbackDirForSnapshot(checkpoint_path, ids.SnapshotId.init(2));
    {
        const file = try tmp.dir.createFile(std.testing.io, source_path, .{});
        defer file.close(std.testing.io);
        try file.writeStreamingAll(std.testing.io, "too large");
    }

    var dest_dir = try storage.openScrollbackDirForSnapshot(
        checkpoint_path,
        ids.SnapshotId.init(2),
    );
    defer dest_dir.close(std.testing.io);
    try testing.expectError(
        error.SavedScrollbackTooLarge,
        storage.copyScrollbackFileToDir(
            source_path,
            dest_dir,
            std.fs.path.basename(dest_path),
            4,
        ),
    );
    try testing.expectError(error.FileNotFound, tmp.dir.access(std.testing.io, dest_path, .{}));
}

test "workspace storage prunes unreferenced scrollback sidecars" {
    const testing = std.testing;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const storage = storage_mod.Storage.init(testing.allocator, tmp.dir);
    const checkpoint_path = try storage.checkpointFilenameAlloc("workspace-key-1");
    defer testing.allocator.free(checkpoint_path);
    const snapshot_id = ids.SnapshotId.init(1);
    const keep_path = try storage.scrollbackFilenameAlloc(
        checkpoint_path,
        snapshot_id,
        ids.SessionId.init(1),
    );
    defer testing.allocator.free(keep_path);
    const stale_path = try storage.scrollbackFilenameAlloc(
        checkpoint_path,
        snapshot_id,
        ids.SessionId.init(8),
    );
    defer testing.allocator.free(stale_path);

    try storage.ensureScrollbackDir(checkpoint_path);
    try storage.ensureScrollbackDirForSnapshot(checkpoint_path, snapshot_id);
    {
        const file = try tmp.dir.createFile(std.testing.io, keep_path, .{});
        defer file.close(std.testing.io);
        try file.writeStreamingAll(std.testing.io, "saved scrollback");
    }
    {
        const file = try tmp.dir.createFile(std.testing.io, stale_path, .{});
        defer file.close(std.testing.io);
        try file.writeStreamingAll(std.testing.io, "stale scrollback");
    }

    var value = buildSnapshot();
    var sessions = [_]snapshot.SessionRecord{fixture_sessions[0]};
    sessions[0].scrollback_path = keep_path;
    value.sessions = &sessions;

    try storage.pruneScrollbackDirForSnapshot(checkpoint_path, value);
    try tmp.dir.access(std.testing.io, keep_path, .{});
    try testing.expectError(error.FileNotFound, tmp.dir.access(std.testing.io, stale_path, .{}));
}

test "workspace storage bounds scrollback pruning" {
    const testing = std.testing;

    {
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();

        const storage = storage_mod.Storage.init(testing.allocator, tmp.dir);
        const checkpoint_path = try storage.checkpointFilenameAlloc("workspace-key-1");
        defer testing.allocator.free(checkpoint_path);

        try storage.ensureScrollbackDir(checkpoint_path);
        const sidecar_dirname = try storage.scrollbackDirnameAlloc(checkpoint_path);
        defer testing.allocator.free(sidecar_dirname);

        var sidecar_dir = try tmp.dir.openDir(std.testing.io, sidecar_dirname, .{});
        defer sidecar_dir.close(std.testing.io);

        for (0..(storage_mod.Storage.max_prune_snapshot_dirs + 1)) |i| {
            var buf: [64]u8 = undefined;
            const dirname = try std.fmt.bufPrint(&buf, "snapshot-{d}", .{i + 1});
            try sidecar_dir.createDir(std.testing.io, dirname, .default_dir);
        }

        try testing.expectError(
            error.WorkspaceScrollbackPruneBudgetExceeded,
            storage.pruneScrollbackDirForSnapshot(checkpoint_path, buildSnapshot()),
        );
    }

    {
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();

        const storage = storage_mod.Storage.init(testing.allocator, tmp.dir);
        const checkpoint_path = try storage.checkpointFilenameAlloc("workspace-key-1");
        defer testing.allocator.free(checkpoint_path);

        try storage.ensureScrollbackDir(checkpoint_path);
        const sidecar_dirname = try storage.scrollbackDirnameAlloc(checkpoint_path);
        defer testing.allocator.free(sidecar_dirname);

        var sidecar_dir = try tmp.dir.openDir(std.testing.io, sidecar_dirname, .{});
        defer sidecar_dir.close(std.testing.io);

        for (0..(storage_mod.Storage.max_prune_entries + 1)) |i| {
            var buf: [64]u8 = undefined;
            const filename = try std.fmt.bufPrint(&buf, "junk-{d}", .{i});
            const file = try sidecar_dir.createFile(std.testing.io, filename, .{});
            file.close(std.testing.io);
        }

        try testing.expectError(
            error.WorkspaceScrollbackPruneBudgetExceeded,
            storage.pruneScrollbackDirForSnapshot(checkpoint_path, buildSnapshot()),
        );
    }
}

test "workspace storage does not recursively delete unexpected scrollback trees" {
    const testing = std.testing;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const storage = storage_mod.Storage.init(testing.allocator, tmp.dir);
    const checkpoint_path = try storage.checkpointFilenameAlloc("workspace-key-1");
    defer testing.allocator.free(checkpoint_path);
    const snapshot_id = ids.SnapshotId.init(1);

    try storage.ensureScrollbackDirForSnapshot(checkpoint_path, snapshot_id);
    const sidecar_dirname = try storage.scrollbackDirnameAlloc(checkpoint_path);
    defer testing.allocator.free(sidecar_dirname);

    const unexpected_top = try std.fmt.allocPrint(
        testing.allocator,
        "{s}/unexpected/child",
        .{sidecar_dirname},
    );
    defer testing.allocator.free(unexpected_top);
    try tmp.dir.createDirPath(std.testing.io, unexpected_top);

    const unexpected_snapshot_child = try std.fmt.allocPrint(
        testing.allocator,
        "{s}/snapshot-99/nested/child",
        .{sidecar_dirname},
    );
    defer testing.allocator.free(unexpected_snapshot_child);
    try tmp.dir.createDirPath(std.testing.io, unexpected_snapshot_child);

    try storage.pruneScrollbackDirForSnapshot(checkpoint_path, buildSnapshot());
    try tmp.dir.access(std.testing.io, unexpected_top, .{});
    try tmp.dir.access(std.testing.io, unexpected_snapshot_child, .{});
}

test "workspace storage does not preserve invalid scrollback sidecar references" {
    const testing = std.testing;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const storage = storage_mod.Storage.init(testing.allocator, tmp.dir);
    const checkpoint_path = try storage.checkpointFilenameAlloc("workspace-key-1");
    defer testing.allocator.free(checkpoint_path);
    const invalid_path = try std.fmt.allocPrint(
        testing.allocator,
        "{s}.scrollback/session-1.vt",
        .{checkpoint_path},
    );
    defer testing.allocator.free(invalid_path);

    try storage.ensureScrollbackDir(checkpoint_path);
    {
        const file = try tmp.dir.createFile(std.testing.io, invalid_path, .{});
        defer file.close(std.testing.io);
        try file.writeStreamingAll(std.testing.io, "invalid saved scrollback");
    }

    var value = buildSnapshot();
    var sessions = [_]snapshot.SessionRecord{fixture_sessions[0]};
    sessions[0].scrollback_path = invalid_path;
    value.sessions = &sessions;

    try storage.pruneScrollbackDirForSnapshot(checkpoint_path, value);
    try testing.expectError(error.FileNotFound, tmp.dir.access(std.testing.io, invalid_path, .{}));
}

test "workspace snapshot validates workspace-level split topology" {
    const workspace_children = [_][]const u8{ "split-a-root", "split-b-root" };
    const split_a_children = [_][]const u8{"tab-a-root"};
    const split_b_children = [_][]const u8{"tab-b-root"};
    const tab_a_children = [_][]const u8{"leaf-a"};
    const tab_b_children = [_][]const u8{"leaf-b"};

    const value: snapshot.Snapshot = .{
        .snapshot_id = ids.SnapshotId.init(2),
        .saved_at = "2026-03-22T12:45:00Z",
        .workspace = .{
            .workspace_id = ids.WorkspaceId.init(2),
            .workspace_key = "workspace-key-2",
            .name = "Split Workspace",
            .layout_root_node_id = "workspace-root",
            .selected_window_id = ids.WindowId.init(1),
            .selected_split_id = ids.SplitId.init(2),
            .selected_tab_id = ids.TabId.init(5),
            .selected_session_id = ids.SessionId.init(11),
        },
        .splits = &.{
            .{
                .split_id = ids.SplitId.init(2),
                .window_id = ids.WindowId.init(1),
                .ordinal = 0,
                .root_layout_node_id = "split-a-root",
            },
            .{
                .split_id = ids.SplitId.init(3),
                .window_id = ids.WindowId.init(1),
                .ordinal = 1,
                .root_layout_node_id = "split-b-root",
            },
        },
        .tabs = &.{
            .{
                .tab_id = ids.TabId.init(5),
                .ordinal = 0,
            },
            .{
                .tab_id = ids.TabId.init(6),
                .ordinal = 1,
            },
        },
        .layout = &.{
            .{
                .layout_node_id = "workspace-root",
                .node_type = .split,
                .split_direction = .right,
                .child_ids = &workspace_children,
            },
            .{
                .layout_node_id = "split-a-root",
                .tab_id = ids.TabId.init(5),
                .node_type = .split_root,
                .child_ids = &split_a_children,
            },
            .{
                .layout_node_id = "tab-a-root",
                .tab_id = ids.TabId.init(5),
                .node_type = .tab_root,
                .child_ids = &tab_a_children,
            },
            .{
                .layout_node_id = "leaf-a",
                .tab_id = ids.TabId.init(5),
                .node_type = .session_leaf,
                .session_id = ids.SessionId.init(11),
            },
            .{
                .layout_node_id = "split-b-root",
                .tab_id = ids.TabId.init(6),
                .node_type = .split_root,
                .child_ids = &split_b_children,
            },
            .{
                .layout_node_id = "tab-b-root",
                .tab_id = ids.TabId.init(6),
                .node_type = .tab_root,
                .child_ids = &tab_b_children,
            },
            .{
                .layout_node_id = "leaf-b",
                .tab_id = ids.TabId.init(6),
                .node_type = .session_leaf,
                .session_id = ids.SessionId.init(12),
            },
        },
        .sessions = &.{
            .{
                .session_id = ids.SessionId.init(11),
                .tab_id = ids.TabId.init(5),
                .cwd = "/home/ignat/code/ghostty",
                .command = .{ .shell = "zsh" },
                .focus_preferred = true,
            },
            .{
                .session_id = ids.SessionId.init(12),
                .tab_id = ids.TabId.init(6),
                .cwd = "/home/ignat/code/specs",
                .command = .{ .shell = "nvim" },
            },
        },
    };

    try value.validate();
}

test "workspace snapshot rejects selected tab outside the selected split" {
    const testing = std.testing;

    var value = buildSnapshot();
    value.workspace.selected_split_id = ids.SplitId.init(999);

    try testing.expectError(error.SelectedSplitNotFound, value.validate());

    value.workspace.selected_split_id = ids.SplitId.init(1);
    value.workspace.selected_tab_id = ids.TabId.init(1);
    value.tabs = &.{
        .{
            .tab_id = ids.TabId.init(1),
            .ordinal = 0,
            .title_override = "Main",
        },
        .{
            .tab_id = ids.TabId.init(2),
            .ordinal = 1,
            .title_override = "Other",
        },
    };
    value.splits = &.{
        .{
            .split_id = ids.SplitId.init(1),
            .window_id = ids.WindowId.init(1),
            .ordinal = 0,
            .root_layout_node_id = "split-1-root",
        },
        .{
            .split_id = ids.SplitId.init(2),
            .window_id = ids.WindowId.init(1),
            .ordinal = 1,
            .root_layout_node_id = "split-2-root",
        },
    };
    value.layout = &.{
        .{
            .layout_node_id = "workspace-root",
            .node_type = .split,
            .split_direction = .right,
            .child_ids = &.{ "split-1-root", "split-2-root" },
        },
        .{
            .layout_node_id = "split-1-root",
            .tab_id = ids.TabId.init(1),
            .node_type = .split_root,
            .child_ids = &.{"tab-1-root"},
        },
        .{
            .layout_node_id = "tab-1-root",
            .tab_id = ids.TabId.init(1),
            .node_type = .tab_root,
            .child_ids = &.{"leaf-1"},
        },
        .{
            .layout_node_id = "leaf-1",
            .tab_id = ids.TabId.init(1),
            .node_type = .session_leaf,
            .session_id = ids.SessionId.init(1),
        },
        .{
            .layout_node_id = "split-2-root",
            .tab_id = ids.TabId.init(2),
            .node_type = .split_root,
            .child_ids = &.{"tab-2-root"},
        },
        .{
            .layout_node_id = "tab-2-root",
            .tab_id = ids.TabId.init(2),
            .node_type = .tab_root,
            .child_ids = &.{"leaf-2"},
        },
        .{
            .layout_node_id = "leaf-2",
            .tab_id = ids.TabId.init(2),
            .node_type = .session_leaf,
            .session_id = ids.SessionId.init(2),
        },
    };
    value.sessions = &.{
        .{
            .session_id = ids.SessionId.init(1),
            .tab_id = ids.TabId.init(1),
            .cwd = "/home/ignat/code/ghostty",
            .command = .{ .shell = "zsh" },
        },
        .{
            .session_id = ids.SessionId.init(2),
            .tab_id = ids.TabId.init(2),
            .cwd = "/home/ignat/code/specs",
            .command = .{ .shell = "nvim" },
        },
    };
    value.workspace.layout_root_node_id = "workspace-root";
    value.workspace.selected_split_id = ids.SplitId.init(1);
    value.workspace.selected_tab_id = ids.TabId.init(2);

    try testing.expectError(error.SelectedTabOutsideSplit, value.validate());
}

test "workspace snapshot rejects selected session outside the selected tab" {
    const testing = std.testing;

    var value = buildSnapshot();
    value.workspace.selected_tab_id = ids.TabId.init(999);
    value.workspace.selected_session_id = ids.SessionId.init(1);

    try testing.expectError(error.SelectedTabNotFound, value.validate());

    value.tabs = &.{
        .{
            .tab_id = ids.TabId.init(1),
            .ordinal = 0,
            .title_override = "Main",
        },
        .{
            .tab_id = ids.TabId.init(2),
            .ordinal = 1,
            .title_override = "Other",
        },
    };
    value.splits = &.{
        .{
            .split_id = ids.SplitId.init(1),
            .window_id = ids.WindowId.init(1),
            .ordinal = 0,
            .root_layout_node_id = "split-1-root",
        },
        .{
            .split_id = ids.SplitId.init(2),
            .window_id = ids.WindowId.init(1),
            .ordinal = 1,
            .root_layout_node_id = "split-2-root",
        },
    };
    value.layout = &.{
        .{
            .layout_node_id = "workspace-root",
            .node_type = .split,
            .split_direction = .right,
            .child_ids = &.{ "split-1-root", "split-2-root" },
        },
        .{
            .layout_node_id = "split-1-root",
            .tab_id = ids.TabId.init(1),
            .node_type = .split_root,
            .child_ids = &.{"tab-1-root"},
        },
        .{
            .layout_node_id = "tab-1-root",
            .tab_id = ids.TabId.init(1),
            .node_type = .tab_root,
            .child_ids = &.{"leaf-1"},
        },
        .{
            .layout_node_id = "leaf-1",
            .tab_id = ids.TabId.init(1),
            .node_type = .session_leaf,
            .session_id = ids.SessionId.init(1),
        },
        .{
            .layout_node_id = "split-2-root",
            .tab_id = ids.TabId.init(2),
            .node_type = .split_root,
            .child_ids = &.{"tab-2-root"},
        },
        .{
            .layout_node_id = "tab-2-root",
            .tab_id = ids.TabId.init(2),
            .node_type = .tab_root,
            .child_ids = &.{"leaf-2"},
        },
        .{
            .layout_node_id = "leaf-2",
            .tab_id = ids.TabId.init(2),
            .node_type = .session_leaf,
            .session_id = ids.SessionId.init(2),
        },
    };
    value.sessions = &.{
        .{
            .session_id = ids.SessionId.init(1),
            .tab_id = ids.TabId.init(1),
            .cwd = "/home/ignat/code/ghostty",
            .command = .{ .shell = "zsh" },
        },
        .{
            .session_id = ids.SessionId.init(2),
            .tab_id = ids.TabId.init(2),
            .cwd = "/home/ignat/code/specs",
            .command = .{ .shell = "nvim" },
        },
    };
    value.workspace.layout_root_node_id = "workspace-root";
    value.workspace.selected_split_id = ids.SplitId.init(1);
    value.workspace.selected_tab_id = ids.TabId.init(1);
    value.workspace.selected_session_id = ids.SessionId.init(2);

    try testing.expectError(error.SelectedSessionOutsideTab, value.validate());
}

test "workspace snapshot serializes runtime workspace layout roots" {
    const testing = std.testing;

    var runtime_registry = registry.Registry.init(testing.allocator);
    defer runtime_registry.deinit();

    const runtime = try runtime_registry.createWorkspace(
        "ghostty",
        "ghostty",
        "2026-03-25T00:00:00Z",
    );
    const runtime_alloc = runtime.runtimeAllocator();

    runtime.workspace.layout_root_id = "workspace-root";
    runtime.workspace.selected_window_id = ids.WindowId.init(1);
    runtime.workspace.selected_split_id = ids.SplitId.init(10);
    runtime.workspace.selected_tab_id = ids.TabId.init(20);
    runtime.workspace.selected_session_id = ids.SessionId.init(30);

    try runtime.windows.append(testing.allocator, .{
        .window_id = ids.WindowId.init(1),
        .workspace_id = runtime.workspace.workspace_id,
        .is_active = true,
        .is_quick_terminal = false,
        .split_ids = try runtime_alloc.dupe(ids.SplitId, &.{ ids.SplitId.init(10), ids.SplitId.init(11) }),
    });
    try runtime.splits.append(testing.allocator, .{
        .split_id = ids.SplitId.init(10),
        .workspace_id = runtime.workspace.workspace_id,
        .window_id = ids.WindowId.init(1),
        .title = "left",
        .ordinal = 0,
        .tab_ids = try runtime_alloc.dupe(ids.TabId, &.{ids.TabId.init(20)}),
        .layout_root_id = "split-10-root",
    });
    try runtime.splits.append(testing.allocator, .{
        .split_id = ids.SplitId.init(11),
        .workspace_id = runtime.workspace.workspace_id,
        .window_id = ids.WindowId.init(1),
        .title = "right",
        .ordinal = 1,
        .tab_ids = try runtime_alloc.dupe(ids.TabId, &.{ids.TabId.init(21)}),
        .layout_root_id = "split-11-root",
    });
    try runtime.tabs.append(testing.allocator, .{
        .tab_id = ids.TabId.init(20),
        .split_id = ids.SplitId.init(10),
        .workspace_id = runtime.workspace.workspace_id,
        .window_id = ids.WindowId.init(1),
        .title = "shell",
        .layout_root_id = "tab-20-root",
        .ordinal = 0,
    });
    try runtime.tabs.append(testing.allocator, .{
        .tab_id = ids.TabId.init(21),
        .split_id = ids.SplitId.init(11),
        .workspace_id = runtime.workspace.workspace_id,
        .window_id = ids.WindowId.init(1),
        .title = "docs",
        .layout_root_id = "tab-21-root",
        .ordinal = 0,
    });
    try runtime.layout.append(testing.allocator, .{
        .layout_node_id = "workspace-root",
        .workspace_id = runtime.workspace.workspace_id,
        .split_id = ids.SplitId.init(10),
        .node_type = .split,
        .split_direction = .right,
        .child_ids = &.{ "split-10-root", "split-11-root" },
    });
    try runtime.layout.append(testing.allocator, .{
        .layout_node_id = "split-10-root",
        .workspace_id = runtime.workspace.workspace_id,
        .split_id = ids.SplitId.init(10),
        .tab_id = ids.TabId.init(20),
        .node_type = .split_root,
        .child_ids = &.{"tab-20-root"},
        .is_selected = true,
    });
    try runtime.layout.append(testing.allocator, .{
        .layout_node_id = "split-11-root",
        .workspace_id = runtime.workspace.workspace_id,
        .split_id = ids.SplitId.init(11),
        .tab_id = ids.TabId.init(21),
        .node_type = .split_root,
        .child_ids = &.{"tab-21-root"},
    });
    try runtime.layout.append(testing.allocator, .{
        .layout_node_id = "tab-20-root",
        .workspace_id = runtime.workspace.workspace_id,
        .split_id = ids.SplitId.init(10),
        .tab_id = ids.TabId.init(20),
        .node_type = .tab,
        .child_ids = &.{"leaf-30"},
        .is_selected = true,
    });
    try runtime.layout.append(testing.allocator, .{
        .layout_node_id = "tab-21-root",
        .workspace_id = runtime.workspace.workspace_id,
        .split_id = ids.SplitId.init(11),
        .tab_id = ids.TabId.init(21),
        .node_type = .tab,
        .child_ids = &.{"leaf-31"},
    });
    try runtime.layout.append(testing.allocator, .{
        .layout_node_id = "leaf-30",
        .workspace_id = runtime.workspace.workspace_id,
        .split_id = ids.SplitId.init(10),
        .tab_id = ids.TabId.init(20),
        .node_type = .session_leaf,
        .session_id = ids.SessionId.init(30),
        .is_selected = true,
    });
    try runtime.layout.append(testing.allocator, .{
        .layout_node_id = "leaf-31",
        .workspace_id = runtime.workspace.workspace_id,
        .split_id = ids.SplitId.init(11),
        .tab_id = ids.TabId.init(21),
        .node_type = .session_leaf,
        .session_id = ids.SessionId.init(31),
    });
    try runtime.sessions.append(testing.allocator, .{
        .session_id = ids.SessionId.init(30),
        .workspace_id = runtime.workspace.workspace_id,
        .window_id = ids.WindowId.init(1),
        .tab_id = ids.TabId.init(20),
        .split_id = ids.SplitId.init(10),
        .layout_node_id = "leaf-30",
        .title = "shell",
        .cwd = "/home/ignat/code/ghostty",
        .command = .{ .shell = "zsh" },
        .focus_state = .focused,
    });
    try runtime.sessions.append(testing.allocator, .{
        .session_id = ids.SessionId.init(31),
        .workspace_id = runtime.workspace.workspace_id,
        .window_id = ids.WindowId.init(1),
        .tab_id = ids.TabId.init(21),
        .split_id = ids.SplitId.init(11),
        .layout_node_id = "leaf-31",
        .title = "docs",
        .cwd = "/home/ignat/code/specs",
        .command = .{ .shell = "nvim" },
        .focus_state = .background,
    });

    const value = try snapshot.fromRuntimeAlloc(
        testing.allocator,
        ids.SnapshotId.init(3),
        "2026-03-25T01:00:00Z",
        runtime,
    );
    defer value.deinit(testing.allocator);

    try value.validate();
    try testing.expectEqualStrings("workspace-root", value.workspace.layout_root_node_id.?);
    try testing.expectEqual(@as(usize, 2), value.splits.len);
    try testing.expectEqual(@as(usize, 7), value.layout.len);
}

test "workspace checkpoint preserves restorable launch metadata" {
    const testing = std.testing;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const storage = storage_mod.Storage.init(testing.allocator, tmp.dir);
    const filename = try storage.writeCheckpoint(buildSnapshot());
    defer testing.allocator.free(filename);

    const loaded = try storage.readSnapshotAlloc(testing.allocator, filename);
    defer loaded.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), loaded.sessions.len);
    try testing.expectEqualStrings("/home/ignat/code/ghostty", loaded.sessions[0].cwd);
    try testing.expectEqualStrings("zig", loaded.sessions[0].command.argv[0]);
    try testing.expectEqualStrings("build", loaded.sessions[0].command.argv[1]);
    try testing.expectEqual(@as(usize, 1), loaded.sessions[0].env_overrides.len);
    try testing.expectEqualStrings("FOO", loaded.sessions[0].env_overrides[0].key);
    try testing.expectEqualStrings("bar", loaded.sessions[0].env_overrides[0].value);
    try testing.expectEqualStrings("shell", loaded.sessions[0].title_override.?);
}
