const builtin = @import("builtin");
const std = @import("std");
const global = @import("../../global.zig");
const internal_os = @import("../../os/main.zig");
const compat_file = @import("../../lib/compat/file.zig");
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
        file: std.Io.File,

        pub fn deinit(self: *Transaction) void {
            self.file.unlock(global.io());
            self.file.close(global.io());
            self.* = undefined;
        }
    };

    pub const CheckpointCommitState = enum {
        uncommitted,
        committed,
    };

    pub const OpenedScrollbackFile = struct {
        path: []const u8,
        file: ?std.Io.File,
    };

    pub const OpenedSnapshot = struct {
        snapshot: snapshot.Snapshot,
        scrollback_files: []OpenedScrollbackFile,

        pub fn deinit(self: *OpenedSnapshot, alloc: std.mem.Allocator) void {
            for (self.scrollback_files) |entry| {
                if (entry.file) |file| file.close(global.io());
            }
            alloc.free(self.scrollback_files);
            self.snapshot.deinit(alloc);
            self.* = undefined;
        }

        pub fn takeScrollbackFile(
            self: *OpenedSnapshot,
            path: []const u8,
        ) ?std.Io.File {
            for (self.scrollback_files) |*entry| {
                if (!std.mem.eql(u8, entry.path, path)) continue;
                const file = entry.file orelse return null;
                entry.file = null;
                return file;
            }
            return null;
        }

        pub fn hasScrollbackPath(
            self: *const OpenedSnapshot,
            path: []const u8,
        ) bool {
            for (self.scrollback_files) |entry| {
                if (std.mem.eql(u8, entry.path, path)) return true;
            }
            return false;
        }
    };

    allocator: std.mem.Allocator,
    dir: std.Io.Dir,

    pub fn init(allocator: std.mem.Allocator, dir: std.Io.Dir) Storage {
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
        errdefer file.close(global.io());
        const stat = try file.stat(global.io());
        if (stat.kind != .file) return error.InvalidWorkspaceStorageFile;

        const acquired = switch (mode) {
            .blocking => acquired: {
                try file.lock(global.io(), .exclusive);
                break :acquired true;
            },
            .nonblocking => try file.tryLock(global.io(), .exclusive),
        };
        if (!acquired) return error.WorkspaceStorageBusy;

        return .{ .file = file };
    }

    fn openTransactionLockFile(self: Storage) !std.Io.File {
        while (true) {
            return self.dir.createFile(global.io(), transaction_lock_filename, .{
                .read = true,
                .truncate = false,
                .exclusive = true,
                .permissions = .fromMode(0o600),
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
    ) !std.Io.File {
        const parsed = parseScrollbackSidecarPath(relative_path) orelse
            return error.InvalidWorkspaceScrollbackPath;

        var sidecar_dir = try self.dir.openDir(global.io(), parsed.checkpoint_dir, .{
            .follow_symlinks = false,
        });
        defer sidecar_dir.close(global.io());

        var snapshot_dir = try sidecar_dir.openDir(global.io(), parsed.snapshot_dir, .{
            .follow_symlinks = false,
        });
        defer snapshot_dir.close(global.io());

        return try openFileReadNoFollow(snapshot_dir, parsed.session_file);
    }

    pub fn openScrollbackDirForSnapshot(
        self: Storage,
        checkpoint_path: []const u8,
        snapshot_id: ids.SnapshotId,
    ) !std.Io.Dir {
        if (!validCheckpointFilename(checkpoint_path)) return error.InvalidCheckpointPath;

        const sidecar_dirname = try self.scrollbackDirnameAlloc(checkpoint_path);
        defer self.allocator.free(sidecar_dirname);

        var sidecar_dir = try self.dir.openDir(global.io(), sidecar_dirname, .{
            .follow_symlinks = false,
        });
        defer sidecar_dir.close(global.io());

        const snapshot_dirname = try std.fmt.allocPrint(
            self.allocator,
            "snapshot-{d}",
            .{snapshot_id.raw()},
        );
        defer self.allocator.free(snapshot_dirname);

        return try sidecar_dir.openDir(global.io(), snapshot_dirname, .{
            .follow_symlinks = false,
        });
    }

    pub fn copyScrollbackFileToDir(
        self: Storage,
        source_relative_path: []const u8,
        dest_dir: std.Io.Dir,
        dest_filename: []const u8,
        max_bytes: u64,
    ) !u64 {
        if (!validScrollbackSessionFilename(dest_filename)) {
            return error.InvalidWorkspaceScrollbackPath;
        }

        const source = try self.openScrollbackFileRead(source_relative_path);
        defer source.close(global.io());

        const stat = try source.stat(global.io());
        if (stat.kind != .file) return error.InvalidWorkspaceScrollbackFile;
        if (stat.size > max_bytes) return error.SavedScrollbackTooLarge;

        var write_buf: [4096]u8 = undefined;
        var atomic_file = try dest_dir.createFileAtomic(global.io(), dest_filename, .{
            .permissions = .fromMode(0o600),
            .replace = true,
        });
        defer atomic_file.deinit(global.io());
        var file_writer = atomic_file.file.writer(global.io(), &write_buf);

        var read_buf: [4096]u8 = undefined;
        var copied: u64 = 0;
        while (true) {
            const n = source.readStreaming(global.io(), &.{&read_buf}) catch |err| switch (err) {
                error.EndOfStream => break,
                else => return err,
            };
            if (n == 0) continue;
            copied += @intCast(n);
            if (copied > max_bytes) return error.SavedScrollbackTooLarge;
            try file_writer.interface.writeAll(read_buf[0..n]);
        }

        try file_writer.flush();
        try atomic_file.file.sync(global.io());
        try atomic_file.replace(global.io());
        try syncDir(dest_dir);
        return copied;
    }

    pub fn resetScrollbackDir(self: Storage, checkpoint_path: []const u8) !void {
        const dirname = try self.scrollbackDirnameAlloc(checkpoint_path);
        defer self.allocator.free(dirname);

        try self.dir.deleteTree(global.io(), dirname);
        try self.dir.createDirPath(global.io(), dirname);
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
        defer sidecar_dir.close(global.io());

        const snapshot_dirname = try std.fmt.allocPrint(
            self.allocator,
            "snapshot-{d}",
            .{snapshot_id.raw()},
        );
        defer self.allocator.free(snapshot_dirname);

        var snapshot_dir = try makeOpenDirNoFollow(sidecar_dir, snapshot_dirname, .{});
        defer snapshot_dir.close(global.io());

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

        var sidecar_dir = try self.dir.openDir(global.io(), sidecar_dirname, .{
            .follow_symlinks = false,
        });
        defer sidecar_dir.close(global.io());

        const snapshot_dirname = try std.fmt.allocPrint(
            self.allocator,
            "snapshot-{d}",
            .{snapshot_id.raw()},
        );
        defer self.allocator.free(snapshot_dirname);

        try sidecar_dir.createDir(global.io(), snapshot_dirname, .default_dir);
        errdefer sidecar_dir.deleteTree(global.io(), snapshot_dirname) catch {};

        var snapshot_dir = try sidecar_dir.openDir(global.io(), snapshot_dirname, .{
            .follow_symlinks = false,
        });
        defer snapshot_dir.close(global.io());

        try syncDir(snapshot_dir);
        try syncDir(sidecar_dir);
        try syncDir(self.dir);
    }

    pub fn ensureScrollbackDir(self: Storage, checkpoint_path: []const u8) !void {
        const dirname = try self.scrollbackDirnameAlloc(checkpoint_path);
        defer self.allocator.free(dirname);

        var sidecar_dir = try makeOpenDirNoFollow(self.dir, dirname, .{});
        defer sidecar_dir.close(global.io());
        try syncDir(sidecar_dir);
        try syncDir(self.dir);
    }

    pub fn deleteScrollbackDir(self: Storage, checkpoint_path: []const u8) !void {
        const dirname = try self.scrollbackDirnameAlloc(checkpoint_path);
        defer self.allocator.free(dirname);

        try self.dir.deleteTree(global.io(), dirname);
        try syncDir(self.dir);
    }

    pub fn deleteScrollbackSnapshotDir(
        self: Storage,
        checkpoint_path: []const u8,
        snapshot_id: ids.SnapshotId,
    ) !void {
        const sidecar_dirname = try self.scrollbackDirnameAlloc(checkpoint_path);
        defer self.allocator.free(sidecar_dirname);

        var sidecar_dir = try self.dir.openDir(global.io(), sidecar_dirname, .{
            .iterate = true,
            .follow_symlinks = false,
        });
        defer sidecar_dir.close(global.io());

        const snapshot_dirname = try std.fmt.allocPrint(
            self.allocator,
            "snapshot-{d}",
            .{snapshot_id.raw()},
        );
        defer self.allocator.free(snapshot_dirname);

        try sidecar_dir.deleteTree(global.io(), snapshot_dirname);
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

        var sidecar_dir = self.dir.openDir(global.io(), dirname, .{
            .iterate = true,
            .follow_symlinks = false,
        }) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer sidecar_dir.close(global.io());

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

        var sidecar_dir = self.dir.openDir(global.io(), dirname, .{
            .iterate = true,
            .follow_symlinks = false,
        }) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer sidecar_dir.close(global.io());

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

    pub fn readSnapshotWithScrollbackAllocAssumeLocked(
        self: Storage,
        alloc: std.mem.Allocator,
        filename: []const u8,
        max_scrollback_bytes: u64,
    ) !OpenedSnapshot {
        var value = try self.readSnapshotAlloc(alloc, filename);
        errdefer value.deinit(alloc);

        var files: std.ArrayList(OpenedScrollbackFile) = .empty;
        errdefer {
            for (files.items) |entry| {
                if (entry.file) |file| file.close(global.io());
            }
            files.deinit(alloc);
        }

        for (value.sessions) |session| {
            const path = session.scrollback_path orelse continue;
            const file = self.openScrollbackFileRead(path) catch |err| switch (err) {
                error.FileNotFound,
                error.AccessDenied,
                error.PermissionDenied,
                error.NotDir,
                error.SymLinkLoop,
                error.Unsupported,
                error.InvalidWorkspaceScrollbackPath,
                => continue,
                else => return err,
            };
            errdefer file.close(global.io());
            const stat = file.stat(global.io()) catch {
                file.close(global.io());
                continue;
            };
            if (stat.kind != .file or stat.size > max_scrollback_bytes) {
                file.close(global.io());
                continue;
            }
            try files.append(alloc, .{
                .path = path,
                .file = file,
            });
        }

        return .{
            .snapshot = value,
            .scrollback_files = try files.toOwnedSlice(alloc),
        };
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
        return self.writeCheckpointTrackedReplacingPathAssumeLocked(
            value,
            null,
            commit_state,
        );
    }

    pub fn writeCheckpointTrackedReplacingPathAssumeLocked(
        self: Storage,
        value: snapshot.Snapshot,
        previous_path: ?[]const u8,
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

        const update = try buildCatalogWithCheckpoint(
            self.allocator,
            catalog,
            value,
            final_name,
            previous_path,
        );
        defer update.deinit(self.allocator);

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

        self.writeCheckpointFileAtomic(
            final_name,
            data,
            commit_state,
        ) catch |err| {
            if (commit_state.* == .committed) {
                self.rollbackAtomicFile(final_name, previous_data) catch
                    return error.WorkspaceCheckpointRollbackFailed;
                commit_state.* = .uncommitted;
            }
            return err;
        };
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

        for (update.replaced_artifacts) |artifact| {
            if (!std.mem.eql(u8, artifact.path, final_name)) {
                try self.deleteCheckpointArtifacts(
                    artifact,
                    if (artifact.workspace_key == null) artifact.path else null,
                );
            }
        }
        if (previous_path) |path| {
            if (!std.mem.eql(u8, path, final_name)) {
                try self.deleteCheckpointPathArtifacts(path);
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
            error.FileNotFound => {
                const checkpoint_path = try self.checkpointFilenameAlloc(workspace_key);
                defer self.allocator.free(checkpoint_path);
                return self.deleteCheckpointPathArtifacts(checkpoint_path);
            },
            else => return err,
        };
        defer catalog.deinit(self.allocator);

        const update = try buildCatalogWithoutMatching(self.allocator, catalog, .workspace_key, workspace_key);
        defer {
            update.catalog.deinit(self.allocator);
            if (update.replaced_artifact) |artifact| artifact.deinit(self.allocator);
        }

        if (update.replaced_artifact == null) {
            const checkpoint_path = try self.checkpointFilenameAlloc(workspace_key);
            defer self.allocator.free(checkpoint_path);
            return self.deleteCheckpointPathArtifacts(checkpoint_path);
        }

        try self.writeCatalog(update.catalog, catalog_filename);

        try self.deleteCheckpointArtifacts(update.replaced_artifact.?, null);
    }

    pub fn pruneCheckpointPath(self: Storage, checkpoint_path: []const u8) !void {
        var transaction = try self.beginTransaction(.blocking);
        defer transaction.deinit();
        return self.pruneCheckpointPathAssumeLocked(checkpoint_path);
    }

    pub fn pruneCheckpointWithFallbackPath(
        self: Storage,
        workspace_key: []const u8,
        fallback_path: ?[]const u8,
    ) !void {
        var transaction = try self.beginTransaction(.blocking);
        defer transaction.deinit();

        const expected_path = try self.checkpointFilenameAlloc(workspace_key);
        defer self.allocator.free(expected_path);
        var catalog = self.readCatalogAlloc(
            self.allocator,
            catalog_filename,
        ) catch |err| switch (err) {
            error.FileNotFound => {
                try self.deleteCheckpointPathArtifacts(expected_path);
                if (fallback_path) |path| {
                    if (!std.mem.eql(u8, path, expected_path)) {
                        try self.deleteCheckpointPathArtifacts(path);
                    }
                }
                return;
            },
            else => return err,
        };
        defer catalog.deinit(self.allocator);

        const update = try buildCatalogWithoutWorkspaceKeyOrPath(
            self.allocator,
            catalog,
            workspace_key,
            fallback_path,
        );
        defer update.deinit(self.allocator);

        if (update.artifacts.len == 0) {
            try self.deleteCheckpointPathArtifacts(expected_path);
            if (fallback_path) |path| {
                if (!std.mem.eql(u8, path, expected_path)) {
                    try self.deleteCheckpointPathArtifacts(path);
                }
            }
            return;
        }

        try self.writeCatalog(update.catalog, catalog_filename);
        for (update.artifacts) |artifact| {
            try self.deleteCheckpointArtifacts(
                artifact.value,
                if (artifact.matched_by_path) artifact.value.path else null,
            );
        }
        try self.deleteCheckpointPathArtifacts(expected_path);
        if (fallback_path) |path| {
            if (!std.mem.eql(u8, path, expected_path)) {
                try self.deleteCheckpointPathArtifacts(path);
            }
        }
    }

    fn pruneCheckpointPathAssumeLocked(
        self: Storage,
        checkpoint_path: []const u8,
    ) !void {
        var catalog = self.readCatalogAlloc(self.allocator, catalog_filename) catch |err| switch (err) {
            error.FileNotFound => return self.deleteCheckpointPathArtifacts(
                checkpoint_path,
            ),
            else => return err,
        };
        defer catalog.deinit(self.allocator);

        const update = try buildCatalogWithoutMatching(self.allocator, catalog, .path, checkpoint_path);
        defer {
            update.catalog.deinit(self.allocator);
            if (update.replaced_artifact) |artifact| artifact.deinit(self.allocator);
        }

        if (update.replaced_artifact == null) {
            return self.deleteCheckpointPathArtifacts(checkpoint_path);
        }

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
        defer file.close(global.io());

        const stat = try file.stat(global.io());
        if (stat.kind != .file) return error.InvalidWorkspaceStorageFile;
        if (stat.size > max_bytes) return error.FileTooBig;
        return try compat_file.readToEndAlloc(file, alloc, max_bytes);
    }

    fn writeAtomicFileAlloc(self: Storage, filename: []const u8, data: []const u8) !void {
        var write_buf: [4096]u8 = undefined;
        var atomic_file = try self.dir.createFileAtomic(global.io(), filename, .{
            .permissions = .fromMode(0o600),
            .replace = true,
        });
        defer atomic_file.deinit(global.io());
        var file_writer = atomic_file.file.writer(global.io(), &write_buf);

        try file_writer.interface.writeAll(data);
        try file_writer.flush();
        try atomic_file.file.sync(global.io());
        try atomic_file.replace(global.io());
        try syncDir(self.dir);
    }

    fn writeCheckpointFileAtomic(
        self: Storage,
        filename: []const u8,
        data: []const u8,
        commit_state: *CheckpointCommitState,
    ) !void {
        var write_buf: [4096]u8 = undefined;
        var atomic_file = try self.dir.createFileAtomic(global.io(), filename, .{
            .permissions = .fromMode(0o600),
            .replace = true,
        });
        defer atomic_file.deinit(global.io());
        var file_writer = atomic_file.file.writer(global.io(), &write_buf);

        try file_writer.interface.writeAll(data);
        try file_writer.flush();
        try atomic_file.file.sync(global.io());
        try atomic_file.replace(global.io());
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

        self.dir.deleteFile(global.io(), filename) catch |err| switch (err) {
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

        return self.deleteCheckpointPathArtifacts(artifact.path);
    }

    fn deleteCheckpointPathArtifacts(
        self: Storage,
        checkpoint_path: []const u8,
    ) !void {
        if (!validCheckpointFilename(checkpoint_path)) return;
        self.dir.deleteFile(global.io(), checkpoint_path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
        try self.deleteScrollbackDir(checkpoint_path);
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
    parent: std.Io.Dir,
    name: []const u8,
    options: std.Io.Dir.OpenOptions,
) !std.Io.Dir {
    return parent.openDir(global.io(), name, .{
        .access_sub_paths = options.access_sub_paths,
        .iterate = options.iterate,
        .follow_symlinks = false,
    }) catch |err| switch (err) {
        error.FileNotFound => {
            parent.createDir(global.io(), name, .default_dir) catch |make_err| switch (make_err) {
                error.PathAlreadyExists => {},
                else => return make_err,
            };
            return try parent.openDir(global.io(), name, .{
                .access_sub_paths = options.access_sub_paths,
                .iterate = options.iterate,
                .follow_symlinks = false,
            });
        },
        else => return err,
    };
}

fn openFileReadNoFollow(dir: std.Io.Dir, filename: []const u8) anyerror!std.Io.File {
    return try openRegularFileRead(dir, filename);
}

fn openFileReadWriteNoFollow(
    dir: std.Io.Dir,
    filename: []const u8,
) !std.Io.File {
    return dir.openFile(global.io(), filename, .{
        .mode = .read_write,
        .allow_directory = false,
        .follow_symlinks = false,
    });
}

fn openRegularFileRead(dir: std.Io.Dir, filename: []const u8) !std.Io.File {
    return dir.openFile(global.io(), filename, .{
        .mode = .read_only,
        .allow_directory = false,
        .follow_symlinks = false,
    });
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
    dir: std.Io.Dir,
    rel_dirname: []const u8,
    value: snapshot.Snapshot,
    budget: *ScrollbackPruneBudget,
) !bool {
    var empty = true;

    var it = dir.iterate();
    while (try it.next(global.io())) |entry| {
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
            var snapshot_dir = dir.openDir(global.io(), entry.name, .{
                .iterate = true,
                .follow_symlinks = false,
            }) catch |err| switch (err) {
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
            defer snapshot_dir.close(global.io());

            break :snapshot_empty try pruneScrollbackSnapshotDirBounded(
                alloc,
                snapshot_dir,
                snapshot_rel_dir,
                value,
                budget,
            );
        };
        if (snapshot_empty) {
            dir.deleteDir(global.io(), entry.name) catch |err| switch (err) {
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
    dir: std.Io.Dir,
    rel_dirname: []const u8,
    value: snapshot.Snapshot,
    budget: *ScrollbackPruneBudget,
) !bool {
    var empty = true;

    var it = dir.iterate();
    while (try it.next(global.io())) |entry| {
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
            dir.deleteFile(global.io(), entry.name) catch |err| switch (err) {
                error.FileNotFound => {},
                else => return err,
            };
        }
    }

    return empty;
}

fn checkScrollbackDirBudgetBounded(
    dir: std.Io.Dir,
    budget: *ScrollbackPruneBudget,
) !void {
    var it = dir.iterate();
    while (try it.next(global.io())) |entry| {
        try budget.visitEntry();
        if (entry.kind != .directory or !validScrollbackSnapshotDirname(entry.name)) continue;

        budget.snapshot_dirs += 1;
        if (budget.snapshot_dirs > Storage.max_prune_snapshot_dirs) return error.WorkspaceScrollbackPruneBudgetExceeded;

        {
            var snapshot_dir = dir.openDir(global.io(), entry.name, .{
                .iterate = true,
                .follow_symlinks = false,
            }) catch |err| switch (err) {
                error.FileNotFound,
                error.NotDir,
                error.SymLinkLoop,
                => continue,
                else => return err,
            };
            defer snapshot_dir.close(global.io());

            try checkScrollbackSnapshotBudgetBounded(snapshot_dir, budget);
        }
    }
}

fn checkScrollbackSnapshotBudgetBounded(
    dir: std.Io.Dir,
    budget: *ScrollbackPruneBudget,
) !void {
    var it = dir.iterate();
    while (try it.next(global.io())) |entry| {
        try budget.visitEntry();
        if (entry.kind != .file or !validScrollbackSessionFilename(entry.name)) continue;

        budget.session_files += 1;
        if (budget.session_files > Storage.max_prune_session_files) return error.WorkspaceScrollbackPruneBudgetExceeded;
    }
}

fn deleteUnexpectedScrollbackEntry(dir: std.Io.Dir, entry: std.Io.Dir.Entry) !void {
    switch (entry.kind) {
        .file, .sym_link => dir.deleteFile(global.io(), entry.name) catch |err| switch (err) {
            error.FileNotFound => {},
            error.IsDir,
            error.NotDir,
            => {},
            else => return err,
        },
        .directory => dir.deleteDir(global.io(), entry.name) catch |err| switch (err) {
            error.FileNotFound => {},
            error.DirNotEmpty,
            error.NotDir,
            => {},
            else => return err,
        },
        else => dir.deleteFile(global.io(), entry.name) catch |err| switch (err) {
            error.FileNotFound,
            error.IsDir,
            error.NotDir,
            => {},
            else => return err,
        },
    }
}

fn entryStillExists(dir: std.Io.Dir, entry: std.Io.Dir.Entry) bool {
    dir.access(global.io(), entry.name, .{}) catch return false;
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

fn syncDir(dir: std.Io.Dir) !void {
    if (comptime builtin.os.tag == .windows) return;
    const rc = std.posix.system.fsync(dir.handle);
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
) !?std.Io.Dir {
    const storage_path = try defaultStoragePathAlloc(alloc);
    defer alloc.free(storage_path);

    return std.Io.Dir.openDirAbsolute(global.io(), storage_path, .{}) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
}

pub fn createDefaultStorageDirAlloc(
    alloc: std.mem.Allocator,
) !std.Io.Dir {
    const storage_path = try defaultStoragePathAlloc(alloc);
    defer alloc.free(storage_path);

    std.Io.Dir.cwd().createDirPath(global.io(), storage_path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    return try std.Io.Dir.openDirAbsolute(global.io(), storage_path, .{});
}

pub fn defaultStoragePathAlloc(
    alloc: std.mem.Allocator,
) ![]u8 {
    var env = try global.environMap();
    defer env.deinit();
    return internal_os.xdg.state(alloc, &env, .{
        .subdir = "ghostty/workspaces",
    });
}

pub fn readDefaultCatalogAlloc(
    alloc: std.mem.Allocator,
) !snapshot.Catalog {
    var dir = try openDefaultStorageDirAlloc(alloc) orelse return .{};
    defer dir.close(global.io());

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

const CheckpointCatalogUpdate = struct {
    catalog: snapshot.Catalog,
    replaced_artifacts: []CheckpointArtifact,

    fn deinit(self: CheckpointCatalogUpdate, alloc: std.mem.Allocator) void {
        self.catalog.deinit(alloc);
        for (self.replaced_artifacts) |artifact| artifact.deinit(alloc);
        alloc.free(self.replaced_artifacts);
    }
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

const PruneArtifact = struct {
    value: CheckpointArtifact,
    matched_by_path: bool,
};

const CatalogPruneUpdate = struct {
    catalog: snapshot.Catalog,
    artifacts: []PruneArtifact,

    fn deinit(self: CatalogPruneUpdate, alloc: std.mem.Allocator) void {
        self.catalog.deinit(alloc);
        for (self.artifacts) |artifact| artifact.value.deinit(alloc);
        alloc.free(self.artifacts);
    }
};

fn buildCatalogWithCheckpoint(
    alloc: std.mem.Allocator,
    catalog: snapshot.Catalog,
    value: snapshot.Snapshot,
    path: []const u8,
    previous_path: ?[]const u8,
) !CheckpointCatalogUpdate {
    const value_workspace_key = value.workspace.workspace_key orelse
        return error.MissingWorkspaceKey;
    var entries: std.ArrayList(snapshot.CatalogEntry) = .empty;
    errdefer {
        for (entries.items) |entry| entry.deinit(alloc);
        entries.deinit(alloc);
    }
    var artifacts: std.ArrayList(CheckpointArtifact) = .empty;
    errdefer {
        for (artifacts.items) |artifact| artifact.deinit(alloc);
        artifacts.deinit(alloc);
    }

    for (catalog.entries) |entry| {
        const key_matches = if (entry.workspace_key) |entry_workspace_key|
            std.mem.eql(u8, entry_workspace_key, value_workspace_key)
        else
            false;
        const previous_path_matches = entry.workspace_key == null and
            if (previous_path) |old_path|
                std.mem.eql(u8, entry.path, old_path)
            else
                false;
        if (key_matches or previous_path_matches) {
            var artifact = try checkpointArtifactAlloc(alloc, entry);
            artifacts.append(alloc, artifact) catch |err| {
                artifact.deinit(alloc);
                return err;
            };
            continue;
        }

        var cloned = try entry.cloneAlloc(alloc);
        entries.append(alloc, cloned) catch |err| {
            cloned.deinit(alloc);
            return err;
        };
    }

    var canonical = try snapshot.catalogEntryAlloc(alloc, value, path);
    entries.append(alloc, canonical) catch |err| {
        canonical.deinit(alloc);
        return err;
    };

    const owned_entries = try entries.toOwnedSlice(alloc);
    errdefer {
        for (owned_entries) |entry| entry.deinit(alloc);
        alloc.free(owned_entries);
    }
    const owned_artifacts = try artifacts.toOwnedSlice(alloc);
    errdefer {
        for (owned_artifacts) |artifact| artifact.deinit(alloc);
        alloc.free(owned_artifacts);
    }
    return .{
        .catalog = .{
            .version = catalog.version,
            .entries = owned_entries,
        },
        .replaced_artifacts = owned_artifacts,
    };
}

fn buildCatalogWithoutWorkspaceKeyOrPath(
    alloc: std.mem.Allocator,
    catalog: snapshot.Catalog,
    workspace_key: []const u8,
    fallback_path: ?[]const u8,
) !CatalogPruneUpdate {
    var entries: std.ArrayList(snapshot.CatalogEntry) = .empty;
    errdefer {
        for (entries.items) |entry| entry.deinit(alloc);
        entries.deinit(alloc);
    }
    var artifacts: std.ArrayList(PruneArtifact) = .empty;
    errdefer {
        for (artifacts.items) |artifact| artifact.value.deinit(alloc);
        artifacts.deinit(alloc);
    }

    for (catalog.entries) |entry| {
        const key_matches = if (entry.workspace_key) |entry_key|
            std.mem.eql(u8, entry_key, workspace_key)
        else
            false;
        const path_matches = if (fallback_path) |path|
            std.mem.eql(u8, entry.path, path)
        else
            false;
        if (key_matches or path_matches) {
            var artifact: PruneArtifact = .{
                .value = try checkpointArtifactAlloc(alloc, entry),
                .matched_by_path = !key_matches,
            };
            artifacts.append(alloc, artifact) catch |err| {
                artifact.value.deinit(alloc);
                return err;
            };
            continue;
        }

        var cloned = try entry.cloneAlloc(alloc);
        entries.append(alloc, cloned) catch |err| {
            cloned.deinit(alloc);
            return err;
        };
    }

    const owned_entries = try entries.toOwnedSlice(alloc);
    errdefer {
        for (owned_entries) |entry| entry.deinit(alloc);
        alloc.free(owned_entries);
    }
    const owned_artifacts = try artifacts.toOwnedSlice(alloc);
    errdefer {
        for (owned_artifacts) |artifact| artifact.value.deinit(alloc);
        alloc.free(owned_artifacts);
    }
    return .{
        .catalog = .{
            .version = catalog.version,
            .entries = owned_entries,
        },
        .artifacts = owned_artifacts,
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

fn testBuildCatalogWithCheckpointAllocationFailures(
    alloc: std.mem.Allocator,
) !void {
    const catalog_entries = [_]snapshot.CatalogEntry{.{
        .snapshot_id = ids.SnapshotId.init(1),
        .workspace_id = ids.WorkspaceId.init(1),
        .workspace_key = "workspace-key",
        .workspace_name = "old workspace",
        .saved_at = "2026-01-01T00:00:00Z",
        .path = "old.json",
    }};
    const value: snapshot.Snapshot = .{
        .snapshot_id = ids.SnapshotId.init(2),
        .saved_at = "2026-01-02T00:00:00Z",
        .workspace = .{
            .workspace_id = ids.WorkspaceId.init(2),
            .workspace_key = "workspace-key",
            .name = "new workspace",
        },
        .tabs = &.{},
        .layout = &.{},
        .sessions = &.{},
    };

    const update = try buildCatalogWithCheckpoint(
        alloc,
        .{ .entries = &catalog_entries },
        value,
        "new.json",
        null,
    );
    defer {
        update.deinit(alloc);
    }
}

test "catalog replacement cleans initialized entries on allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        testBuildCatalogWithCheckpointAllocationFailures,
        .{},
    );
}
