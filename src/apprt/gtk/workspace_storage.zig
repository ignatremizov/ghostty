const builtin = @import("builtin");
const std = @import("std");
const internal_os = @import("../../os/main.zig");
const snapshot = @import("workspace_snapshot.zig");
const ids = @import("workspace_ids.zig");

pub const Storage = struct {
    pub const catalog_filename = "catalog.json";
    pub const transaction_lock_filename = ".transactions.lock";
    pub const max_snapshot_json_bytes = 16 * 1024 * 1024;
    pub const max_catalog_json_bytes = 4 * 1024 * 1024;
    pub const max_prune_entries = 4096;
    pub const max_prune_snapshot_dirs = 512;
    pub const max_prune_session_files = 4096;

    pub const TransactionLockMode = enum {
        blocking,
        nonblocking,
    };

    pub const Transaction = struct {
        file: std.fs.File,

        pub fn deinit(self: *Transaction) void {
            self.file.unlock();
            self.file.close();
            self.* = undefined;
        }
    };

    pub const CheckpointCommitState = enum {
        uncommitted,
        committed,
    };

    allocator: std.mem.Allocator,
    dir: std.fs.Dir,

    pub fn init(allocator: std.mem.Allocator, dir: std.fs.Dir) Storage {
        return .{
            .allocator = allocator,
            .dir = dir,
        };
    }

    pub fn beginTransaction(
        self: Storage,
        mode: TransactionLockMode,
    ) !Transaction {
        const file = try self.openTransactionLockFile();
        errdefer file.close();
        const stat = try file.stat();
        if (stat.kind != .file) return error.InvalidWorkspaceStorageFile;

        const acquired = switch (mode) {
            .blocking => acquired: {
                try file.lock(.exclusive);
                break :acquired true;
            },
            .nonblocking => try file.tryLock(.exclusive),
        };
        if (!acquired) return error.WorkspaceStorageBusy;

        return .{ .file = file };
    }

    fn openTransactionLockFile(self: Storage) !std.fs.File {
        while (true) {
            return self.dir.createFile(transaction_lock_filename, .{
                .read = true,
                .truncate = false,
                .exclusive = true,
                .mode = 0o600,
            }) catch |err| switch (err) {
                error.PathAlreadyExists => openFileReadWriteNoFollow(
                    self.dir,
                    transaction_lock_filename,
                ) catch |open_err| switch (open_err) {
                    error.FileNotFound => continue,
                    else => return open_err,
                },
                else => return err,
            };
        }
    }

    pub fn checkpointFilenameAlloc(self: Storage, workspace_key: []const u8) ![]u8 {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.allocator);

        for (workspace_key) |c| {
            switch (c) {
                'a'...'z', 'A'...'Z', '0'...'9', '-', '_', '.' => try buf.append(self.allocator, c),
                else => try buf.append(self.allocator, '_'),
            }
        }

        if (buf.items.len == 0) return error.InvalidWorkspaceKey;
        const hash = std.hash.Wyhash.hash(0, workspace_key);
        return std.fmt.allocPrint(self.allocator, "{s}-{x}.json", .{ buf.items, hash });
    }

    pub fn scrollbackDirnameAlloc(self: Storage, checkpoint_path: []const u8) ![]u8 {
        if (!validCheckpointFilename(checkpoint_path)) return error.InvalidCheckpointPath;
        return std.fmt.allocPrint(self.allocator, "{s}.scrollback", .{checkpoint_path});
    }

    pub fn scrollbackSnapshotDirnameAlloc(
        self: Storage,
        checkpoint_path: []const u8,
        snapshot_id: ids.SnapshotId,
    ) ![]u8 {
        if (!validCheckpointFilename(checkpoint_path)) return error.InvalidCheckpointPath;
        return std.fmt.allocPrint(
            self.allocator,
            "{s}.scrollback/snapshot-{d}",
            .{ checkpoint_path, snapshot_id.raw() },
        );
    }

    pub fn scrollbackFilenameAlloc(
        self: Storage,
        checkpoint_path: []const u8,
        snapshot_id: ids.SnapshotId,
        session_id: ids.SessionId,
    ) ![]u8 {
        if (!validCheckpointFilename(checkpoint_path)) return error.InvalidCheckpointPath;
        return std.fmt.allocPrint(
            self.allocator,
            "{s}.scrollback/snapshot-{d}/session-{d}.vt",
            .{ checkpoint_path, snapshot_id.raw(), session_id.raw() },
        );
    }

    pub fn validScrollbackSidecarPath(path: []const u8) bool {
        return parseScrollbackSidecarPath(path) != null;
    }

    pub fn validScrollbackSidecarPathForCheckpoint(
        path: []const u8,
        checkpoint_path: []const u8,
    ) bool {
        if (!validCheckpointFilename(checkpoint_path)) return false;
        const parsed = parseScrollbackSidecarPath(path) orelse return false;
        return std.mem.eql(u8, parsed.checkpoint_path, checkpoint_path);
    }

    pub fn validScrollbackSidecarPathForCheckpointAndSession(
        path: []const u8,
        checkpoint_path: []const u8,
        session_id: ids.SessionId,
    ) bool {
        if (!validCheckpointFilename(checkpoint_path)) return false;
        const parsed = parseScrollbackSidecarPath(path) orelse return false;
        return std.mem.eql(u8, parsed.checkpoint_path, checkpoint_path) and
            parsed.session_id == session_id;
    }

    pub fn openScrollbackFileRead(
        self: Storage,
        relative_path: []const u8,
    ) !std.fs.File {
        const parsed = parseScrollbackSidecarPath(relative_path) orelse
            return error.InvalidWorkspaceScrollbackPath;

        var sidecar_dir = try self.dir.openDir(parsed.checkpoint_dir, .{
            .no_follow = true,
        });
        defer sidecar_dir.close();

        var snapshot_dir = try sidecar_dir.openDir(parsed.snapshot_dir, .{
            .no_follow = true,
        });
        defer snapshot_dir.close();

        return try openFileReadNoFollow(snapshot_dir, parsed.session_file);
    }

    pub fn openScrollbackDirForSnapshot(
        self: Storage,
        checkpoint_path: []const u8,
        snapshot_id: ids.SnapshotId,
    ) !std.fs.Dir {
        if (!validCheckpointFilename(checkpoint_path)) return error.InvalidCheckpointPath;

        const sidecar_dirname = try self.scrollbackDirnameAlloc(checkpoint_path);
        defer self.allocator.free(sidecar_dirname);

        var sidecar_dir = try self.dir.openDir(sidecar_dirname, .{
            .no_follow = true,
        });
        defer sidecar_dir.close();

        const snapshot_dirname = try std.fmt.allocPrint(
            self.allocator,
            "snapshot-{d}",
            .{snapshot_id.raw()},
        );
        defer self.allocator.free(snapshot_dirname);

        return try sidecar_dir.openDir(snapshot_dirname, .{
            .no_follow = true,
        });
    }

    pub fn copyScrollbackFileToDir(
        self: Storage,
        source_relative_path: []const u8,
        dest_dir: std.fs.Dir,
        dest_filename: []const u8,
        max_bytes: u64,
    ) !u64 {
        if (!validScrollbackSessionFilename(dest_filename)) {
            return error.InvalidWorkspaceScrollbackPath;
        }

        const source = try self.openScrollbackFileRead(source_relative_path);
        defer source.close();

        const stat = try source.stat();
        if (stat.kind != .file) return error.InvalidWorkspaceScrollbackFile;
        if (stat.size > max_bytes) return error.SavedScrollbackTooLarge;

        var write_buf: [4096]u8 = undefined;
        var atomic_file = try dest_dir.atomicFile(dest_filename, .{
            .mode = 0o600,
            .write_buffer = &write_buf,
        });
        defer atomic_file.deinit();

        var read_buf: [4096]u8 = undefined;
        var copied: u64 = 0;
        while (true) {
            const n = try source.read(read_buf[0..]);
            if (n == 0) break;
            copied += @intCast(n);
            if (copied > max_bytes) return error.SavedScrollbackTooLarge;
            try atomic_file.file_writer.interface.writeAll(read_buf[0..n]);
        }

        try atomic_file.flush();
        try atomic_file.file_writer.file.sync();
        try atomic_file.renameIntoPlace();
        try syncDir(dest_dir);
        return copied;
    }

    pub fn resetScrollbackDir(self: Storage, checkpoint_path: []const u8) !void {
        const dirname = try self.scrollbackDirnameAlloc(checkpoint_path);
        defer self.allocator.free(dirname);

        try self.dir.deleteTree(dirname);
        try self.dir.makePath(dirname);
        try syncDir(self.dir);
    }

    pub fn ensureScrollbackDirForSnapshot(
        self: Storage,
        checkpoint_path: []const u8,
        snapshot_id: ids.SnapshotId,
    ) !void {
        const sidecar_dirname = try self.scrollbackDirnameAlloc(checkpoint_path);
        defer self.allocator.free(sidecar_dirname);

        var sidecar_dir = try makeOpenDirNoFollow(self.dir, sidecar_dirname, .{});
        defer sidecar_dir.close();

        const snapshot_dirname = try std.fmt.allocPrint(
            self.allocator,
            "snapshot-{d}",
            .{snapshot_id.raw()},
        );
        defer self.allocator.free(snapshot_dirname);

        var snapshot_dir = try makeOpenDirNoFollow(sidecar_dir, snapshot_dirname, .{});
        defer snapshot_dir.close();

        try syncDir(snapshot_dir);
        try syncDir(sidecar_dir);
        try syncDir(self.dir);
    }

    pub fn createScrollbackDirForSnapshotExclusive(
        self: Storage,
        checkpoint_path: []const u8,
        snapshot_id: ids.SnapshotId,
    ) !void {
        const sidecar_dirname = try self.scrollbackDirnameAlloc(checkpoint_path);
        defer self.allocator.free(sidecar_dirname);

        var sidecar_dir = try self.dir.openDir(sidecar_dirname, .{
            .no_follow = true,
        });
        defer sidecar_dir.close();

        const snapshot_dirname = try std.fmt.allocPrint(
            self.allocator,
            "snapshot-{d}",
            .{snapshot_id.raw()},
        );
        defer self.allocator.free(snapshot_dirname);

        try sidecar_dir.makeDir(snapshot_dirname);
        errdefer sidecar_dir.deleteTree(snapshot_dirname) catch {};

        var snapshot_dir = try sidecar_dir.openDir(snapshot_dirname, .{
            .no_follow = true,
        });
        defer snapshot_dir.close();

        try syncDir(snapshot_dir);
        try syncDir(sidecar_dir);
        try syncDir(self.dir);
    }

    pub fn ensureScrollbackDir(self: Storage, checkpoint_path: []const u8) !void {
        const dirname = try self.scrollbackDirnameAlloc(checkpoint_path);
        defer self.allocator.free(dirname);

        var sidecar_dir = try makeOpenDirNoFollow(self.dir, dirname, .{});
        defer sidecar_dir.close();
        try syncDir(sidecar_dir);
        try syncDir(self.dir);
    }

    pub fn deleteScrollbackDir(self: Storage, checkpoint_path: []const u8) !void {
        const dirname = try self.scrollbackDirnameAlloc(checkpoint_path);
        defer self.allocator.free(dirname);

        try self.dir.deleteTree(dirname);
        try syncDir(self.dir);
    }

    pub fn deleteScrollbackSnapshotDir(
        self: Storage,
        checkpoint_path: []const u8,
        snapshot_id: ids.SnapshotId,
    ) !void {
        const sidecar_dirname = try self.scrollbackDirnameAlloc(checkpoint_path);
        defer self.allocator.free(sidecar_dirname);

        var sidecar_dir = try self.dir.openDir(sidecar_dirname, .{
            .iterate = true,
            .no_follow = true,
        });
        defer sidecar_dir.close();

        const snapshot_dirname = try std.fmt.allocPrint(
            self.allocator,
            "snapshot-{d}",
            .{snapshot_id.raw()},
        );
        defer self.allocator.free(snapshot_dirname);

        try sidecar_dir.deleteTree(snapshot_dirname);
        try syncDir(sidecar_dir);
        try syncDir(self.dir);
    }

    pub fn pruneScrollbackDirForSnapshot(
        self: Storage,
        checkpoint_path: []const u8,
        value: snapshot.Snapshot,
    ) !void {
        var transaction = try self.beginTransaction(.blocking);
        defer transaction.deinit();
        return self.pruneScrollbackDirForSnapshotAssumeLocked(
            checkpoint_path,
            value,
        );
    }

    pub fn pruneScrollbackDirForSnapshotAssumeLocked(
        self: Storage,
        checkpoint_path: []const u8,
        value: snapshot.Snapshot,
    ) !void {
        const dirname = try self.scrollbackDirnameAlloc(checkpoint_path);
        defer self.allocator.free(dirname);

        var sidecar_dir = self.dir.openDir(dirname, .{ .iterate = true, .no_follow = true }) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer sidecar_dir.close();

        var budget: ScrollbackPruneBudget = .{};
        _ = try pruneScrollbackDirBounded(
            self.allocator,
            sidecar_dir,
            dirname,
            value,
            &budget,
        );
    }

    pub fn checkScrollbackPruneBudget(self: Storage, checkpoint_path: []const u8) !void {
        var transaction = try self.beginTransaction(.blocking);
        defer transaction.deinit();
        return self.checkScrollbackPruneBudgetAssumeLocked(checkpoint_path);
    }

    pub fn checkScrollbackPruneBudgetAssumeLocked(
        self: Storage,
        checkpoint_path: []const u8,
    ) !void {
        const dirname = try self.scrollbackDirnameAlloc(checkpoint_path);
        defer self.allocator.free(dirname);

        var sidecar_dir = self.dir.openDir(dirname, .{ .iterate = true, .no_follow = true }) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer sidecar_dir.close();

        var budget: ScrollbackPruneBudget = .{};
        try checkScrollbackDirBudgetBounded(sidecar_dir, &budget);
    }

    pub fn writeSnapshot(self: Storage, value: snapshot.Snapshot) ![]u8 {
        const workspace_key = value.workspace.workspace_key orelse return error.MissingWorkspaceKey;
        const final_name = try self.checkpointFilenameAlloc(workspace_key);
        errdefer self.allocator.free(final_name);

        try validateSnapshotScrollbackPathsForCheckpoint(value, final_name);

        const data = try value.encodeAlloc(self.allocator);
        defer self.allocator.free(data);
        if (data.len > max_snapshot_json_bytes) return error.FileTooBig;

        try self.writeAtomicFileAlloc(final_name, data);
        return final_name;
    }

    pub fn readSnapshotAlloc(self: Storage, alloc: std.mem.Allocator, filename: []const u8) !snapshot.Snapshot {
        if (!validCheckpointFilename(filename)) return error.InvalidCheckpointPath;

        const data = try self.readRegularFileAlloc(alloc, filename, max_snapshot_json_bytes);
        defer alloc.free(data);
        const value = try snapshot.Snapshot.decodeAlloc(alloc, data);
        errdefer value.deinit(alloc);
        try validateSnapshotScrollbackPathsForCheckpoint(value, filename);
        return value;
    }

    pub fn readCatalogAlloc(self: Storage, alloc: std.mem.Allocator, filename: []const u8) !snapshot.Catalog {
        const data = try self.readRegularFileAlloc(alloc, filename, max_catalog_json_bytes);
        defer alloc.free(data);
        return try snapshot.Catalog.decodeAlloc(alloc, data);
    }

    pub fn writeCheckpoint(self: Storage, value: snapshot.Snapshot) ![]u8 {
        var transaction = try self.beginTransaction(.blocking);
        defer transaction.deinit();

        var commit_state: CheckpointCommitState = .uncommitted;
        return self.writeCheckpointTrackedAssumeLocked(value, &commit_state);
    }

    pub fn writeCheckpointTrackedAssumeLocked(
        self: Storage,
        value: snapshot.Snapshot,
        commit_state: *CheckpointCommitState,
    ) ![]u8 {
        commit_state.* = .uncommitted;
        const workspace_key = value.workspace.workspace_key orelse return error.MissingWorkspaceKey;
        const final_name = try self.checkpointFilenameAlloc(workspace_key);
        errdefer self.allocator.free(final_name);

        try validateSnapshotScrollbackPathsForCheckpoint(value, final_name);

        const previous_catalog_data = self.readRegularFileAlloc(
            self.allocator,
            catalog_filename,
            max_catalog_json_bytes,
        ) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        defer if (previous_catalog_data) |bytes| self.allocator.free(bytes);

        var catalog = if (previous_catalog_data) |bytes|
            try snapshot.Catalog.decodeAlloc(self.allocator, bytes)
        else
            snapshot.Catalog{};
        defer catalog.deinit(self.allocator);

        const update = try buildCatalogWithCheckpoint(self.allocator, catalog, value, final_name);
        defer {
            update.catalog.deinit(self.allocator);
            if (update.replaced_artifact) |artifact| artifact.deinit(self.allocator);
        }

        const data = try value.encodeAlloc(self.allocator);
        defer self.allocator.free(data);
        if (data.len > max_snapshot_json_bytes) return error.FileTooBig;

        const previous_data = self.readRegularFileAlloc(
            self.allocator,
            final_name,
            max_snapshot_json_bytes,
        ) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        defer if (previous_data) |bytes| self.allocator.free(bytes);

        try self.writeCheckpointFileAtomic(
            final_name,
            data,
            commit_state,
        );
        self.writeCatalog(update.catalog, catalog_filename) catch |err| {
            self.rollbackAtomicFile(
                catalog_filename,
                previous_catalog_data,
            ) catch return error.WorkspaceCheckpointRollbackFailed;
            self.rollbackAtomicFile(final_name, previous_data) catch
                return error.WorkspaceCheckpointRollbackFailed;
            commit_state.* = .uncommitted;
            return err;
        };

        if (update.replaced_artifact) |artifact| {
            if (!std.mem.eql(u8, artifact.path, final_name)) {
                self.deleteCheckpointArtifacts(artifact, null) catch {};
            }
        }

        return final_name;
    }

    pub fn pruneCheckpoint(self: Storage, workspace_key: []const u8) !void {
        var transaction = try self.beginTransaction(.blocking);
        defer transaction.deinit();
        return self.pruneCheckpointAssumeLocked(workspace_key);
    }

    fn pruneCheckpointAssumeLocked(self: Storage, workspace_key: []const u8) !void {
        var catalog = self.readCatalogAlloc(self.allocator, catalog_filename) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer catalog.deinit(self.allocator);

        const update = try buildCatalogWithoutMatching(self.allocator, catalog, .workspace_key, workspace_key);
        defer {
            update.catalog.deinit(self.allocator);
            if (update.replaced_artifact) |artifact| artifact.deinit(self.allocator);
        }

        if (update.replaced_artifact == null) return;

        try self.writeCatalog(update.catalog, catalog_filename);

        try self.deleteCheckpointArtifacts(update.replaced_artifact.?, null);
    }

    pub fn pruneCheckpointPath(self: Storage, checkpoint_path: []const u8) !void {
        var transaction = try self.beginTransaction(.blocking);
        defer transaction.deinit();
        return self.pruneCheckpointPathAssumeLocked(checkpoint_path);
    }

    fn pruneCheckpointPathAssumeLocked(
        self: Storage,
        checkpoint_path: []const u8,
    ) !void {
        var catalog = self.readCatalogAlloc(self.allocator, catalog_filename) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer catalog.deinit(self.allocator);

        const update = try buildCatalogWithoutMatching(self.allocator, catalog, .path, checkpoint_path);
        defer {
            update.catalog.deinit(self.allocator);
            if (update.replaced_artifact) |artifact| artifact.deinit(self.allocator);
        }

        if (update.replaced_artifact == null) return;

        try self.writeCatalog(update.catalog, catalog_filename);

        try self.deleteCheckpointArtifacts(update.replaced_artifact.?, checkpoint_path);
    }

    pub fn writeCatalog(self: Storage, value: snapshot.Catalog, filename: []const u8) !void {
        const data = try value.encodeAlloc(self.allocator);
        defer self.allocator.free(data);
        if (data.len > max_catalog_json_bytes) return error.FileTooBig;

        try self.writeAtomicFileAlloc(filename, data);
    }

    fn readRegularFileAlloc(
        self: Storage,
        alloc: std.mem.Allocator,
        filename: []const u8,
        max_bytes: usize,
    ) ![]u8 {
        if (!validStorageFilePath(filename)) return error.InvalidWorkspaceStoragePath;

        const file = try openRegularFileRead(self.dir, filename);
        defer file.close();

        const stat = try file.stat();
        if (stat.kind != .file) return error.InvalidWorkspaceStorageFile;
        if (stat.size > max_bytes) return error.FileTooBig;
        return try file.readToEndAlloc(alloc, max_bytes);
    }

    fn writeAtomicFileAlloc(self: Storage, filename: []const u8, data: []const u8) !void {
        var write_buf: [4096]u8 = undefined;
        var atomic_file = try self.dir.atomicFile(filename, .{
            .mode = 0o600,
            .write_buffer = &write_buf,
        });
        defer atomic_file.deinit();

        try atomic_file.file_writer.interface.writeAll(data);
        try atomic_file.flush();
        try atomic_file.file_writer.file.sync();
        try atomic_file.renameIntoPlace();
        try syncDir(self.dir);
    }

    fn writeCheckpointFileAtomic(
        self: Storage,
        filename: []const u8,
        data: []const u8,
        commit_state: *CheckpointCommitState,
    ) !void {
        var write_buf: [4096]u8 = undefined;
        var atomic_file = try self.dir.atomicFile(filename, .{
            .mode = 0o600,
            .write_buffer = &write_buf,
        });
        defer atomic_file.deinit();

        try atomic_file.file_writer.interface.writeAll(data);
        try atomic_file.flush();
        try atomic_file.file_writer.file.sync();
        try atomic_file.renameIntoPlace();
        commit_state.* = .committed;
        try syncDir(self.dir);
    }

    fn rollbackAtomicFile(
        self: Storage,
        filename: []const u8,
        previous_data: ?[]const u8,
    ) !void {
        if (previous_data) |bytes| {
            return self.writeAtomicFileAlloc(filename, bytes);
        }

        self.dir.deleteFile(filename) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
        try syncDir(self.dir);
    }

    fn deleteCheckpointArtifacts(
        self: Storage,
        artifact: CheckpointArtifact,
        expected_path_override: ?[]const u8,
    ) !void {
        if (expected_path_override) |expected_path| {
            if (!validCheckpointFilename(expected_path)) return;
            if (!std.mem.eql(u8, artifact.path, expected_path)) return;
        } else {
            const workspace_key = artifact.workspace_key orelse return;
            const expected_path = try self.checkpointFilenameAlloc(workspace_key);
            defer self.allocator.free(expected_path);
            if (!std.mem.eql(u8, artifact.path, expected_path)) return;
        }

        self.dir.deleteFile(artifact.path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
        try self.deleteScrollbackDir(artifact.path);
    }
};

fn validCheckpointFilename(path: []const u8) bool {
    if (std.mem.indexOfScalar(u8, path, 0) != null) return false;
    if (std.mem.eql(u8, path, Storage.catalog_filename)) return false;
    if (!std.mem.endsWith(u8, path, ".json")) return false;

    const stem = path[0 .. path.len - ".json".len];
    const hash_start = (std.mem.lastIndexOfScalar(u8, stem, '-') orelse return false) + 1;
    if (hash_start == 1 or hash_start == stem.len) return false;

    for (stem[0 .. hash_start - 1]) |c| {
        switch (c) {
            'a'...'z', 'A'...'Z', '0'...'9', '-', '_', '.' => {},
            else => return false,
        }
    }
    const hash = stem[hash_start..];
    if (hash.len > 16) return false;
    for (hash) |c| {
        switch (c) {
            '0'...'9', 'a'...'f' => {},
            else => return false,
        }
    }
    return true;
}

fn validStorageFilePath(path: []const u8) bool {
    if (std.mem.indexOfScalar(u8, path, 0) != null) return false;
    if (std.mem.indexOfScalar(u8, path, '/') != null) return false;
    if (std.mem.indexOfScalar(u8, path, '\\') != null) return false;
    return std.mem.eql(u8, path, Storage.catalog_filename) or validCheckpointFilename(path);
}

const ScrollbackSidecarPath = struct {
    checkpoint_dir: []const u8,
    checkpoint_path: []const u8,
    snapshot_dir: []const u8,
    session_file: []const u8,
    session_id: ids.SessionId,
};

fn parseScrollbackSidecarPath(path: []const u8) ?ScrollbackSidecarPath {
    if (std.mem.indexOfScalar(u8, path, 0) != null) return null;
    if (std.mem.indexOfScalar(u8, path, '\\') != null) return null;

    var parts = std.mem.splitScalar(u8, path, '/');
    const checkpoint_dir = parts.next() orelse return null;
    const snapshot_dir = parts.next() orelse return null;
    const session_file = parts.next() orelse return null;
    if (parts.next() != null) return null;

    const sidecar_suffix = ".scrollback";
    if (!std.mem.endsWith(u8, checkpoint_dir, sidecar_suffix)) return null;
    const checkpoint_path = checkpoint_dir[0 .. checkpoint_dir.len - sidecar_suffix.len];
    if (!validCheckpointFilename(checkpoint_path)) return null;

    _ = parsePrefixedPositiveInt(snapshot_dir, "snapshot-", "") orelse return null;
    const session_raw = parsePrefixedPositiveInt(session_file, "session-", ".vt") orelse return null;

    return .{
        .checkpoint_dir = checkpoint_dir,
        .checkpoint_path = checkpoint_path,
        .snapshot_dir = snapshot_dir,
        .session_file = session_file,
        .session_id = ids.SessionId.init(session_raw),
    };
}

fn validPrefixedPositiveInt(
    value: []const u8,
    prefix: []const u8,
    suffix: []const u8,
) bool {
    return parsePrefixedPositiveInt(value, prefix, suffix) != null;
}

fn validScrollbackSessionFilename(filename: []const u8) bool {
    return validPrefixedPositiveInt(filename, "session-", ".vt");
}

fn validScrollbackSnapshotDirname(dirname: []const u8) bool {
    return validPrefixedPositiveInt(dirname, "snapshot-", "");
}

fn parsePrefixedPositiveInt(
    value: []const u8,
    prefix: []const u8,
    suffix: []const u8,
) ?u64 {
    if (!std.mem.startsWith(u8, value, prefix)) return null;
    if (!std.mem.endsWith(u8, value, suffix)) return null;
    const start = prefix.len;
    const end = value.len - suffix.len;
    if (start >= end) return null;
    const digits = value[start..end];
    for (digits) |c| switch (c) {
        '0'...'9' => {},
        else => return null,
    };
    const parsed = std.fmt.parseInt(u64, digits, 10) catch return null;
    if (parsed == 0) return null;
    return parsed;
}

fn makeOpenDirNoFollow(
    parent: std.fs.Dir,
    name: []const u8,
    options: std.fs.Dir.OpenOptions,
) !std.fs.Dir {
    return parent.openDir(name, .{
        .access_sub_paths = options.access_sub_paths,
        .iterate = options.iterate,
        .no_follow = true,
    }) catch |err| switch (err) {
        error.FileNotFound => {
            parent.makeDir(name) catch |make_err| switch (make_err) {
                error.PathAlreadyExists => {},
                else => return make_err,
            };
            return try parent.openDir(name, .{
                .access_sub_paths = options.access_sub_paths,
                .iterate = options.iterate,
                .no_follow = true,
            });
        },
        else => return err,
    };
}

fn openFileReadNoFollow(dir: std.fs.Dir, filename: []const u8) anyerror!std.fs.File {
    return try openRegularFileRead(dir, filename);
}

fn openFileReadWriteNoFollow(
    dir: std.fs.Dir,
    filename: []const u8,
) !std.fs.File {
    if (comptime builtin.os.tag == .windows) {
        const windows = std.os.windows;
        const filename_w = try windows.sliceToPrefixedFileW(dir.fd, filename);
        const handle = try windows.OpenFile(filename_w.span(), .{
            .dir = dir.fd,
            .access_mask = windows.SYNCHRONIZE |
                windows.GENERIC_READ |
                windows.GENERIC_WRITE,
            .creation = windows.FILE_OPEN,
            .filter = .file_only,
            .follow_symlinks = false,
        });
        return .{ .handle = handle };
    }

    const filename_z = try std.posix.toPosixPath(filename);
    const fd = try std.posix.openatZ(dir.fd, &filename_z, .{
        .ACCMODE = .RDWR,
        .NOFOLLOW = true,
        .CLOEXEC = true,
        .NOCTTY = true,
    }, 0);
    return .{ .handle = fd };
}

fn openRegularFileRead(dir: std.fs.Dir, filename: []const u8) !std.fs.File {
    if (comptime builtin.os.tag == .windows) {
        const windows = std.os.windows;
        const filename_w = try windows.sliceToPrefixedFileW(dir.fd, filename);
        const handle = try windows.OpenFile(filename_w.span(), .{
            .dir = dir.fd,
            .access_mask = windows.SYNCHRONIZE | windows.GENERIC_READ,
            .creation = windows.FILE_OPEN,
            .filter = .file_only,
            .follow_symlinks = false,
        });
        return .{ .handle = handle };
    }

    const filename_z = try std.posix.toPosixPath(filename);
    const fd = try std.posix.openatZ(dir.fd, &filename_z, .{
        .ACCMODE = .RDONLY,
        .NONBLOCK = true,
        .NOFOLLOW = true,
        .CLOEXEC = true,
        .NOCTTY = true,
    }, 0);
    return .{ .handle = fd };
}

const ScrollbackPruneBudget = struct {
    entries: usize = 0,
    snapshot_dirs: usize = 0,
    session_files: usize = 0,

    fn visitEntry(self: *ScrollbackPruneBudget) !void {
        self.entries += 1;
        if (self.entries > Storage.max_prune_entries) return error.WorkspaceScrollbackPruneBudgetExceeded;
    }
};

fn pruneScrollbackDirBounded(
    alloc: std.mem.Allocator,
    dir: std.fs.Dir,
    rel_dirname: []const u8,
    value: snapshot.Snapshot,
    budget: *ScrollbackPruneBudget,
) !bool {
    var empty = true;

    var it = dir.iterate();
    while (try it.next()) |entry| {
        try budget.visitEntry();
        if (entry.kind != .directory or !validScrollbackSnapshotDirname(entry.name)) {
            try deleteUnexpectedScrollbackEntry(dir, entry);
            if (entryStillExists(dir, entry)) empty = false;
            continue;
        }

        budget.snapshot_dirs += 1;
        if (budget.snapshot_dirs > Storage.max_prune_snapshot_dirs) return error.WorkspaceScrollbackPruneBudgetExceeded;

        const snapshot_rel_dir = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ rel_dirname, entry.name });
        defer alloc.free(snapshot_rel_dir);

        const snapshot_empty = snapshot_empty: {
            var snapshot_dir = dir.openDir(entry.name, .{ .iterate = true, .no_follow = true }) catch |err| switch (err) {
                error.FileNotFound,
                error.NotDir,
                error.SymLinkLoop,
                => {
                    try deleteUnexpectedScrollbackEntry(dir, entry);
                    if (entryStillExists(dir, entry)) empty = false;
                    continue;
                },
                else => return err,
            };
            defer snapshot_dir.close();

            break :snapshot_empty try pruneScrollbackSnapshotDirBounded(
                alloc,
                snapshot_dir,
                snapshot_rel_dir,
                value,
                budget,
            );
        };
        if (snapshot_empty) {
            dir.deleteDir(entry.name) catch |err| switch (err) {
                error.FileNotFound => {},
                error.DirNotEmpty,
                error.NotDir,
                => empty = false,
                else => return err,
            };
        } else {
            empty = false;
        }
    }

    return empty;
}

fn pruneScrollbackSnapshotDirBounded(
    alloc: std.mem.Allocator,
    dir: std.fs.Dir,
    rel_dirname: []const u8,
    value: snapshot.Snapshot,
    budget: *ScrollbackPruneBudget,
) !bool {
    var empty = true;

    var it = dir.iterate();
    while (try it.next()) |entry| {
        try budget.visitEntry();
        if (entry.kind != .file or !validScrollbackSessionFilename(entry.name)) {
            try deleteUnexpectedScrollbackEntry(dir, entry);
            if (entryStillExists(dir, entry)) empty = false;
            continue;
        }

        budget.session_files += 1;
        if (budget.session_files > Storage.max_prune_session_files) return error.WorkspaceScrollbackPruneBudgetExceeded;

        const rel_path = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ rel_dirname, entry.name });
        defer alloc.free(rel_path);
        if (snapshotKeepsScrollbackPath(rel_path, value)) {
            empty = false;
        } else {
            dir.deleteFile(entry.name) catch |err| switch (err) {
                error.FileNotFound => {},
                else => return err,
            };
        }
    }

    return empty;
}

fn checkScrollbackDirBudgetBounded(
    dir: std.fs.Dir,
    budget: *ScrollbackPruneBudget,
) !void {
    var it = dir.iterate();
    while (try it.next()) |entry| {
        try budget.visitEntry();
        if (entry.kind != .directory or !validScrollbackSnapshotDirname(entry.name)) continue;

        budget.snapshot_dirs += 1;
        if (budget.snapshot_dirs > Storage.max_prune_snapshot_dirs) return error.WorkspaceScrollbackPruneBudgetExceeded;

        {
            var snapshot_dir = dir.openDir(entry.name, .{ .iterate = true, .no_follow = true }) catch |err| switch (err) {
                error.FileNotFound,
                error.NotDir,
                error.SymLinkLoop,
                => continue,
                else => return err,
            };
            defer snapshot_dir.close();

            try checkScrollbackSnapshotBudgetBounded(snapshot_dir, budget);
        }
    }
}

fn checkScrollbackSnapshotBudgetBounded(
    dir: std.fs.Dir,
    budget: *ScrollbackPruneBudget,
) !void {
    var it = dir.iterate();
    while (try it.next()) |entry| {
        try budget.visitEntry();
        if (entry.kind != .file or !validScrollbackSessionFilename(entry.name)) continue;

        budget.session_files += 1;
        if (budget.session_files > Storage.max_prune_session_files) return error.WorkspaceScrollbackPruneBudgetExceeded;
    }
}

fn deleteUnexpectedScrollbackEntry(dir: std.fs.Dir, entry: std.fs.Dir.Entry) !void {
    switch (entry.kind) {
        .file, .sym_link => dir.deleteFile(entry.name) catch |err| switch (err) {
            error.FileNotFound => {},
            error.IsDir,
            error.NotDir,
            => {},
            else => return err,
        },
        .directory => dir.deleteDir(entry.name) catch |err| switch (err) {
            error.FileNotFound => {},
            error.DirNotEmpty,
            error.NotDir,
            => {},
            else => return err,
        },
        else => dir.deleteFile(entry.name) catch |err| switch (err) {
            error.FileNotFound,
            error.IsDir,
            error.NotDir,
            => {},
            else => return err,
        },
    }
}

fn entryStillExists(dir: std.fs.Dir, entry: std.fs.Dir.Entry) bool {
    dir.access(entry.name, .{}) catch return false;
    return true;
}

fn snapshotKeepsScrollbackPath(
    rel_path: []const u8,
    value: snapshot.Snapshot,
) bool {
    for (value.sessions) |session| {
        const path = session.scrollback_path orelse continue;
        if (!Storage.validScrollbackSidecarPath(path)) continue;
        if (std.mem.eql(u8, path, rel_path)) return true;
    }

    return false;
}

fn validateSnapshotScrollbackPathsForCheckpoint(
    value: snapshot.Snapshot,
    checkpoint_path: []const u8,
) !void {
    for (value.sessions) |session| {
        const path = session.scrollback_path orelse continue;
        if (!Storage.validScrollbackSidecarPathForCheckpointAndSession(
            path,
            checkpoint_path,
            session.session_id,
        )) {
            return error.InvalidWorkspaceScrollbackPath;
        }
    }
}

fn syncDir(dir: std.fs.Dir) !void {
    if (comptime builtin.os.tag == .windows) return;
    const rc = std.posix.system.fsync(dir.fd);
    switch (std.posix.errno(rc)) {
        .SUCCESS => return,
        .BADF, .INVAL, .ROFS, .OPNOTSUPP => return,
        .IO => return error.InputOutput,
        .NOSPC => return error.NoSpaceLeft,
        .DQUOT => return error.DiskQuota,
        else => |err| return std.posix.unexpectedErrno(err),
    }
}

pub fn openDefaultStorageDirAlloc(
    alloc: std.mem.Allocator,
) !?std.fs.Dir {
    const storage_path = try defaultStoragePathAlloc(alloc);
    defer alloc.free(storage_path);

    return std.fs.openDirAbsolute(storage_path, .{}) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
}

pub fn createDefaultStorageDirAlloc(
    alloc: std.mem.Allocator,
) !std.fs.Dir {
    const storage_path = try defaultStoragePathAlloc(alloc);
    defer alloc.free(storage_path);

    std.fs.cwd().makePath(storage_path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    return try std.fs.openDirAbsolute(storage_path, .{});
}

pub fn defaultStoragePathAlloc(
    alloc: std.mem.Allocator,
) ![]u8 {
    return internal_os.xdg.state(alloc, .{
        .subdir = "ghostty/workspaces",
    });
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
    replaced_artifact: ?CheckpointArtifact = null,
};

const CheckpointArtifact = struct {
    path: []u8,
    workspace_key: ?[]u8 = null,

    fn deinit(self: CheckpointArtifact, alloc: std.mem.Allocator) void {
        alloc.free(self.path);
        if (self.workspace_key) |workspace_key| alloc.free(workspace_key);
    }
};

const CatalogRemovalKey = enum {
    workspace_key,
    path,
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
    var replaced_artifact: ?CheckpointArtifact = null;
    errdefer if (replaced_artifact) |artifact| artifact.deinit(alloc);
    errdefer {
        for (entries[0..initialized]) |entry| entry.deinit(alloc);
        alloc.free(entries);
    }

    var write_index: usize = 0;
    for (catalog.entries, 0..) |entry, index| {
        if (replaced_index != null and index == replaced_index.?) {
            entries[write_index] = try snapshot.catalogEntryAlloc(alloc, value, path);
            replaced_artifact = try checkpointArtifactAlloc(alloc, entry);
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
        .replaced_artifact = replaced_artifact,
    };
}

fn buildCatalogWithoutMatching(
    alloc: std.mem.Allocator,
    catalog: snapshot.Catalog,
    removal_key: CatalogRemovalKey,
    needle: []const u8,
) !CatalogUpdate {
    var removed_index: ?usize = null;
    for (catalog.entries, 0..) |entry, index| {
        if (!catalogEntryMatchesRemovalKey(entry, removal_key, needle)) continue;
        removed_index = index;
        break;
    }

    const entry_count = if (removed_index == null)
        catalog.entries.len
    else
        catalog.entries.len - 1;
    var entries: []snapshot.CatalogEntry = if (entry_count == 0)
        &.{}
    else
        try alloc.alloc(snapshot.CatalogEntry, entry_count);
    var initialized: usize = 0;
    var removed_artifact: ?CheckpointArtifact = null;
    errdefer if (removed_artifact) |artifact| artifact.deinit(alloc);
    errdefer {
        for (entries[0..initialized]) |entry| entry.deinit(alloc);
        if (entry_count > 0) alloc.free(entries);
    }

    var write_index: usize = 0;
    for (catalog.entries, 0..) |entry, index| {
        if (removed_index != null and index == removed_index.?) {
            removed_artifact = try checkpointArtifactAlloc(alloc, entry);
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
        .replaced_artifact = removed_artifact,
    };
}

fn checkpointArtifactAlloc(
    alloc: std.mem.Allocator,
    entry: snapshot.CatalogEntry,
) !CheckpointArtifact {
    const path = try alloc.dupe(u8, entry.path);
    errdefer alloc.free(path);
    const workspace_key = if (entry.workspace_key) |workspace_key|
        try alloc.dupe(u8, workspace_key)
    else
        null;
    errdefer if (workspace_key) |key| alloc.free(key);
    return .{
        .path = path,
        .workspace_key = workspace_key,
    };
}

fn catalogEntryMatchesRemovalKey(
    entry: snapshot.CatalogEntry,
    removal_key: CatalogRemovalKey,
    needle: []const u8,
) bool {
    return switch (removal_key) {
        .workspace_key => if (entry.workspace_key) |workspace_key|
            std.mem.eql(u8, workspace_key, needle)
        else
            false,
        .path => std.mem.eql(u8, entry.path, needle),
    };
}
