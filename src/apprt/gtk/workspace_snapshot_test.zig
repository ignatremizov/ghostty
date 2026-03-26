const std = @import("std");
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
    const catalog: snapshot.Catalog = .{
        .entries = &.{.{
            .snapshot_id = ids.SnapshotId.init(1),
            .workspace_id = ids.WorkspaceId.init(1),
            .workspace_key = "workspace-key-1",
            .workspace_name = "Developer Workspace",
            .saved_at = "2026-03-22T12:00:00Z",
            .path = "snapshot-1.json",
        }},
    };

    try storage.writeCatalog(catalog, storage_mod.Storage.catalog_filename);

    const loaded = try storage.readCatalogAlloc(testing.allocator, storage_mod.Storage.catalog_filename);
    defer loaded.deinit(testing.allocator);

    try testing.expectEqual(@as(u32, 1), loaded.version);
    try testing.expectEqual(@as(usize, 1), loaded.entries.len);
    try testing.expectEqual(ids.WorkspaceId.init(1), loaded.entries[0].workspace_id);
    try testing.expectEqualStrings("workspace-key-1", loaded.entries[0].workspace_key.?);
    try testing.expectEqualStrings("snapshot-1.json", loaded.entries[0].path);
}

test "workspace checkpoint updates latest catalog entry and prunes replaced snapshot" {
    const testing = std.testing;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const storage = storage_mod.Storage.init(testing.allocator, tmp.dir);

    var first_snapshot = buildSnapshot();
    first_snapshot.saved_at = "2026-03-22T12:00:00Z";
    const first_filename = try storage.writeCheckpoint(first_snapshot);
    defer testing.allocator.free(first_filename);
    try testing.expectEqualStrings("snapshot-1.json", first_filename);

    var second_snapshot = buildSnapshot();
    second_snapshot.snapshot_id = ids.SnapshotId.init(2);
    second_snapshot.saved_at = "2026-03-22T12:30:00Z";
    const second_filename = try storage.writeCheckpoint(second_snapshot);
    defer testing.allocator.free(second_filename);
    try testing.expectEqualStrings("snapshot-2.json", second_filename);

    const loaded = try storage.readCatalogAlloc(testing.allocator, storage_mod.Storage.catalog_filename);
    defer loaded.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), loaded.entries.len);
    try testing.expectEqual(ids.SnapshotId.init(2), loaded.entries[0].snapshot_id);
    try testing.expectEqual(ids.WorkspaceId.init(1), loaded.entries[0].workspace_id);
    try testing.expectEqualStrings("workspace-key-1", loaded.entries[0].workspace_key.?);
    try testing.expectEqualStrings("snapshot-2.json", loaded.entries[0].path);
    try testing.expectEqualStrings("2026-03-22T12:30:00Z", loaded.entries[0].saved_at);

    try testing.expectError(error.FileNotFound, tmp.dir.access("snapshot-1.json", .{}));
    try tmp.dir.access("snapshot-2.json", .{});
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
