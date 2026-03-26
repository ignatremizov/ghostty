const std = @import("std");
const internal_os = @import("../../os/main.zig");
const snapshot = @import("workspace_snapshot.zig");
const ids = @import("workspace_ids.zig");

pub const Storage = struct {
    pub const catalog_filename = "catalog.json";

    allocator: std.mem.Allocator,
    dir: std.fs.Dir,

    pub fn init(allocator: std.mem.Allocator, dir: std.fs.Dir) Storage {
        return .{
            .allocator = allocator,
            .dir = dir,
        };
    }

    pub fn snapshotFilenameAlloc(self: Storage, snapshot_id: ids.SnapshotId) ![]u8 {
        var buf: [48]u8 = undefined;
        const id_text = try snapshot_id.format(&buf);
        return std.fmt.allocPrint(self.allocator, "{s}.json", .{id_text});
    }

    pub fn writeSnapshot(self: Storage, value: snapshot.Snapshot) ![]u8 {
        const data = try value.encodeAlloc(self.allocator);
        defer self.allocator.free(data);

        const final_name = try self.snapshotFilenameAlloc(value.snapshot_id);
        errdefer self.allocator.free(final_name);

        const temp_name = try std.fmt.allocPrint(self.allocator, "{s}.tmp", .{final_name});
        defer self.allocator.free(temp_name);

        {
            const file = try self.dir.createFile(temp_name, .{ .truncate = true, .read = true });
            defer file.close();
            try file.writeAll(data);
            try file.sync();
        }

        try self.dir.rename(temp_name, final_name);
        return final_name;
    }

    pub fn readSnapshotAlloc(self: Storage, alloc: std.mem.Allocator, filename: []const u8) !snapshot.Snapshot {
        const data = try self.dir.readFileAlloc(alloc, filename, std.math.maxInt(usize));
        defer alloc.free(data);
        return try snapshot.Snapshot.decodeAlloc(alloc, data);
    }

    pub fn readCatalogAlloc(self: Storage, alloc: std.mem.Allocator, filename: []const u8) !snapshot.Catalog {
        const data = try self.dir.readFileAlloc(alloc, filename, std.math.maxInt(usize));
        defer alloc.free(data);
        return try snapshot.Catalog.decodeAlloc(alloc, data);
    }

    pub fn readWorkspaceKeyAlloc(
        self: Storage,
        alloc: std.mem.Allocator,
        filename: []const u8,
    ) ![]u8 {
        const value = try self.readSnapshotAlloc(alloc, filename);
        defer value.deinit(alloc);

        if (value.workspace.workspace_key) |workspace_key| {
            return try alloc.dupe(u8, workspace_key);
        }

        return try std.fmt.allocPrint(alloc, "legacy:{s}", .{filename});
    }

    pub fn writeCheckpoint(self: Storage, value: snapshot.Snapshot) ![]u8 {
        const final_name = try self.writeSnapshot(value);
        errdefer self.allocator.free(final_name);

        var catalog = self.readCatalogAlloc(self.allocator, catalog_filename) catch |err| switch (err) {
            error.FileNotFound => snapshot.Catalog{},
            else => return err,
        };
        defer catalog.deinit(self.allocator);

        const update = try buildCatalogWithCheckpoint(self.allocator, catalog, value, final_name);
        defer {
            update.catalog.deinit(self.allocator);
            if (update.replaced_path) |path| self.allocator.free(path);
        }

        try self.writeCatalog(update.catalog, catalog_filename);

        if (update.replaced_path) |path| {
            if (!std.mem.eql(u8, path, final_name)) {
                self.dir.deleteFile(path) catch |err| switch (err) {
                    error.FileNotFound => {},
                    else => return err,
                };
            }
        }

        return final_name;
    }

    pub fn pruneCheckpoint(self: Storage, workspace_key: []const u8) !void {
        var catalog = self.readCatalogAlloc(self.allocator, catalog_filename) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer catalog.deinit(self.allocator);

        const update = try buildCatalogWithoutCheckpoint(self.allocator, catalog, workspace_key);
        defer {
            update.catalog.deinit(self.allocator);
            if (update.replaced_path) |path| self.allocator.free(path);
        }

        if (update.replaced_path == null) return;

        try self.writeCatalog(update.catalog, catalog_filename);

        const removed_path = update.replaced_path.?;
        self.dir.deleteFile(removed_path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
    }

    pub fn writeCatalog(self: Storage, value: snapshot.Catalog, filename: []const u8) !void {
        const data = try value.encodeAlloc(self.allocator);
        defer self.allocator.free(data);

        const temp_name = try std.fmt.allocPrint(self.allocator, "{s}.tmp", .{filename});
        defer self.allocator.free(temp_name);

        {
            const file = try self.dir.createFile(temp_name, .{ .truncate = true, .read = true });
            defer file.close();
            try file.writeAll(data);
            try file.sync();
        }

        try self.dir.rename(temp_name, filename);
    }
};

pub fn openDefaultStorageDirAlloc(
    alloc: std.mem.Allocator,
) !?std.fs.Dir {
    const storage_path = try internal_os.xdg.state(alloc, .{
        .subdir = "ghostty/workspaces",
    });
    defer alloc.free(storage_path);

    return std.fs.openDirAbsolute(storage_path, .{}) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
}

pub fn readDefaultCatalogAlloc(
    alloc: std.mem.Allocator,
) !snapshot.Catalog {
    var dir = try openDefaultStorageDirAlloc(alloc) orelse return .{};
    defer dir.close();

    const storage = Storage.init(alloc, dir);
    return storage.readCatalogAlloc(alloc, Storage.catalog_filename) catch |err| switch (err) {
        error.FileNotFound => .{},
        else => return err,
    };
}

const CatalogUpdate = struct {
    catalog: snapshot.Catalog,
    replaced_path: ?[]u8 = null,
};

fn buildCatalogWithCheckpoint(
    alloc: std.mem.Allocator,
    catalog: snapshot.Catalog,
    value: snapshot.Snapshot,
    path: []const u8,
) !CatalogUpdate {
    var replaced_index: ?usize = null;
    for (catalog.entries, 0..) |entry, index| {
        const entry_workspace_key = entry.workspace_key orelse continue;
        const value_workspace_key = value.workspace.workspace_key orelse continue;
        if (!std.mem.eql(u8, entry_workspace_key, value_workspace_key)) continue;
        replaced_index = index;
        break;
    }

    const entry_count = if (replaced_index == null)
        catalog.entries.len + 1
    else
        catalog.entries.len;
    const entries = try alloc.alloc(snapshot.CatalogEntry, entry_count);
    var initialized: usize = 0;
    var replaced_path: ?[]u8 = null;
    errdefer if (replaced_path) |old_path| alloc.free(old_path);
    errdefer {
        for (entries[0..initialized]) |entry| entry.deinit(alloc);
        alloc.free(entries);
    }

    var write_index: usize = 0;
    for (catalog.entries, 0..) |entry, index| {
        if (replaced_index != null and index == replaced_index.?) {
            entries[write_index] = try snapshot.catalogEntryAlloc(alloc, value, path);
            replaced_path = try alloc.dupe(u8, entry.path);
        } else {
            entries[write_index] = try entry.cloneAlloc(alloc);
        }
        initialized += 1;
        write_index += 1;
    }

    if (replaced_index == null) {
        entries[write_index] = try snapshot.catalogEntryAlloc(alloc, value, path);
        initialized += 1;
    }

    return .{
        .catalog = .{
            .version = catalog.version,
            .entries = entries,
        },
        .replaced_path = replaced_path,
    };
}

fn buildCatalogWithoutCheckpoint(
    alloc: std.mem.Allocator,
    catalog: snapshot.Catalog,
    workspace_key: []const u8,
) !CatalogUpdate {
    var removed_index: ?usize = null;
    for (catalog.entries, 0..) |entry, index| {
        const entry_workspace_key = entry.workspace_key orelse continue;
        if (!std.mem.eql(u8, entry_workspace_key, workspace_key)) continue;
        removed_index = index;
        break;
    }

    const entry_count = if (removed_index == null)
        catalog.entries.len
    else
        catalog.entries.len - 1;
    const empty_entries = [_]snapshot.CatalogEntry{};
    var entries: []snapshot.CatalogEntry = if (entry_count == 0)
        empty_entries[0..]
    else
        try alloc.alloc(snapshot.CatalogEntry, entry_count);
    var initialized: usize = 0;
    var removed_path: ?[]u8 = null;
    errdefer if (removed_path) |old_path| alloc.free(old_path);
    errdefer {
        for (entries[0..initialized]) |entry| entry.deinit(alloc);
        if (entry_count > 0) alloc.free(entries);
    }

    var write_index: usize = 0;
    for (catalog.entries, 0..) |entry, index| {
        if (removed_index != null and index == removed_index.?) {
            removed_path = try alloc.dupe(u8, entry.path);
            continue;
        }
        entries[write_index] = try entry.cloneAlloc(alloc);
        initialized += 1;
        write_index += 1;
    }

    return .{
        .catalog = .{
            .version = catalog.version,
            .entries = entries,
        },
        .replaced_path = removed_path,
    };
}
