const std = @import("std");
const adw = @import("adw");
const gdk = @import("gdk");
const gio = @import("gio");
const glib = @import("glib");
const gobject = @import("gobject");
const gtk = @import("gtk");

const i18n = @import("../../../os/main.zig").i18n;
const Common = @import("../class.zig").Common;
const ext = @import("../ext.zig");
const gresource = @import("../build/gresource.zig");
const workspace_registry = @import("../workspace_registry.zig");
const Application = @import("application.zig").Application;
const WorkspacePage = @import("workspace_page.zig").WorkspacePage;

const log = std.log.scoped(.gtk_workspace_sidebar);

const WorkspaceContextAction = enum {
    rename,
    save,
    restore,
    delete_saved,
    open_file,
    reveal,
    close,
};

const WorkspaceContextActionDescriptor = struct {
    label: [*:0]const u8,
    action: WorkspaceContextAction,
    destructive: bool = false,
};

pub const WorkspaceSidebar = extern struct {
    const Self = @This();
    parent_instance: Parent,
    pub const Parent = gtk.Box;
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "GhosttyWorkspaceSidebar",
        .instanceInit = &init,
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    pub const signals = struct {
        pub const @"workspace-selected" = struct {
            pub const name = "workspace-selected";
            pub const connect = impl.connect;
            const impl = gobject.ext.defineSignal(name, Self, &.{*WorkspacePage}, void);
        };

        pub const @"new-workspace" = struct {
            pub const name = "new-workspace";
            pub const connect = impl.connect;
            const impl = gobject.ext.defineSignal(name, Self, &.{}, void);
        };

        pub const @"prompt-workspace-title" = struct {
            pub const name = "prompt-workspace-title";
            pub const connect = impl.connect;
            const impl = gobject.ext.defineSignal(name, Self, &.{*WorkspacePage}, void);
        };

        pub const @"save-workspace" = struct {
            pub const name = "save-workspace";
            pub const connect = impl.connect;
            const impl = gobject.ext.defineSignal(name, Self, &.{*WorkspacePage}, void);
        };

        pub const @"reveal-workspace-snapshot" = struct {
            pub const name = "reveal-workspace-snapshot";
            pub const connect = impl.connect;
            const impl = gobject.ext.defineSignal(name, Self, &.{*WorkspacePage}, void);
        };

        pub const @"open-workspace-snapshot" = struct {
            pub const name = "open-workspace-snapshot";
            pub const connect = impl.connect;
            const impl = gobject.ext.defineSignal(name, Self, &.{*WorkspacePage}, void);
        };

        pub const @"delete-workspace" = struct {
            pub const name = "delete-workspace";
            pub const connect = impl.connect;
            const impl = gobject.ext.defineSignal(name, Self, &.{*WorkspacePage}, void);
        };

        pub const @"close-workspace" = struct {
            pub const name = "close-workspace";
            pub const connect = impl.connect;
            const impl = gobject.ext.defineSignal(name, Self, &.{*WorkspacePage}, void);
        };

        pub const @"restore-workspace" = struct {
            pub const name = "restore-workspace";
            pub const connect = impl.connect;
            const impl = gobject.ext.defineSignal(name, Self, &.{}, void);
        };

        pub const @"restore-workspace-and-close" = struct {
            pub const name = "restore-workspace-and-close";
            pub const connect = impl.connect;
            const impl = gobject.ext.defineSignal(name, Self, &.{*WorkspacePage}, void);
        };
    };

    const Private = struct {
        disposing: bool = false,
        context_menu_popover: ?*gtk.Popover = null,
        workspace_empty_context_popover: ?*gtk.Popover = null,
        context_workspace_page: ?*WorkspacePage = null,
        pending_context_workspace_page: ?*WorkspacePage = null,
        pending_context_workspace_action: ?WorkspaceContextAction = null,
        pending_context_action_ctx: ?*IdleWorkspaceActionContext = null,
        pending_context_action_source: ?c_uint = null,
        pending_workspace_empty_restore: bool = false,
        pending_restore_source: ?c_uint = null,

        workspace_list: *gtk.ListBox,

        pub var offset: c_int = 0;
    };

    fn init(self: *Self, _: *Class) callconv(.c) void {
        gtk.Widget.initTemplate(self.as(gtk.Widget));
        const priv = self.private();
        priv.workspace_list.setSelectionMode(.browse);
        {
            const gesture = gtk.GestureClick.new();
            gesture.as(gtk.GestureSingle).setButton(3);
            _ = gtk.GestureClick.signals.released.connect(
                gesture,
                *Self,
                workspaceListSecondaryClick,
                self,
                .{},
            );
            priv.workspace_list.as(gtk.Widget).addController(gesture.as(gtk.EventController));
        }
    }

    pub fn bindModel(self: *Self, model: *gio.ListModel) void {
        self.private().workspace_list.bindModel(
            model,
            workspaceListCreateWidget,
            self,
            null,
        );
    }

    pub fn syncSelection(self: *Self, idx_: ?c_int) void {
        const priv = self.private();
        const idx = idx_ orelse {
            priv.workspace_list.unselectAll();
            return;
        };
        const row = priv.workspace_list.getRowAtIndex(idx) orelse return;
        if (priv.workspace_list.getSelectedRow() == row) return;
        priv.workspace_list.selectRow(row);
    }

    pub fn updateRowBadge(self: *Self, idx: c_int, text: ?[:0]const u8) void {
        const row = self.private().workspace_list.getRowAtIndex(idx) orelse return;
        const badge_obj = row.as(gobject.Object).getData("workspace-badge") orelse return;
        const badge: *gtk.Label = @ptrCast(@alignCast(badge_obj));
        if (text) |label| {
            badge.setLabel(label);
            badge.as(gtk.Widget).setVisible(1);
        } else {
            badge.as(gtk.Widget).setVisible(0);
        }
    }

    pub fn updateRowDescriptor(
        self: *Self,
        idx: c_int,
        title: [:0]const u8,
        subtitle: [:0]const u8,
        tooltip: ?[:0]const u8,
    ) void {
        const row = self.private().workspace_list.getRowAtIndex(idx) orelse return;
        const title_obj = row.as(gobject.Object).getData("workspace-title-label") orelse return;
        const subtitle_obj = row.as(gobject.Object).getData("workspace-subtitle-label") orelse return;
        const title_label: *gtk.Label = @ptrCast(@alignCast(title_obj));
        const subtitle_label: *gtk.Label = @ptrCast(@alignCast(subtitle_obj));

        title_label.setLabel(title);
        subtitle_label.setLabel(subtitle);
        if (tooltip) |text|
            row.as(gtk.Widget).setTooltipText(text.ptr)
        else
            row.as(gtk.Widget).setTooltipText(null);
    }

    pub fn formatSidebarSubtitle(
        alloc: std.mem.Allocator,
        base_subtitle: ?[:0]const u8,
        counts: workspace_registry.SidebarCounts,
    ) ![:0]u8 {
        const base = if (base_subtitle) |subtitle| subtitle else "";
        if (counts.sessions <= 1 and counts.tabs <= 1 and counts.splits <= 1) {
            return std.fmt.allocPrintSentinel(alloc, "{s}", .{base}, 0);
        }

        if (base.len == 0) {
            return std.fmt.allocPrintSentinel(alloc, "{d} {s}", .{
                counts.sessions,
                if (counts.sessions == 1) "session" else "sessions",
            }, 0);
        }

        return std.fmt.allocPrintSentinel(alloc, "{s} • {d} {s}", .{
            base,
            counts.sessions,
            if (counts.sessions == 1) "session" else "sessions",
        }, 0);
    }

    pub fn formatSidebarTooltip(
        alloc: std.mem.Allocator,
        runtime: *const workspace_registry.WorkspaceRuntime,
    ) !?[:0]const u8 {
        const selected = workspace_registry.selectedSessionDescriptor(runtime) orelse return null;
        return try std.fmt.allocPrintSentinel(alloc, "{d} {s} • {d} {s}\nSelected split: {s}\nSelected tab: {s}\nSelected session: {s}\nWorking directory: {s}", .{
            runtime.workspace.split_ids.len,
            if (runtime.workspace.split_ids.len == 1) "split" else "splits",
            runtime.workspace.session_ids.len,
            if (runtime.workspace.session_ids.len == 1) "session" else "sessions",
            selected.split_title,
            selected.tab_title_override orelse selected.tab_title,
            selected.session_title_override orelse selected.session_title,
            selected.cwd,
        }, 0);
    }

    fn workspaceListCreateWidget(item: *gobject.Object, ud: ?*anyopaque) callconv(.c) *gtk.Widget {
        const page = gobject.ext.cast(adw.TabPage, item) orelse @panic("expected tab page");
        const workspace_page = gobject.ext.cast(WorkspacePage, page.getChild()) orelse @panic("expected workspace page");

        const row = gtk.ListBoxRow.new();
        row.setActivatable(1);
        row.setSelectable(1);
        row.as(gtk.Widget).addCssClass("workspace-row");

        const content = gtk.Box.new(.horizontal, 12);
        content.as(gtk.Widget).setMarginTop(8);
        content.as(gtk.Widget).setMarginBottom(8);
        content.as(gtk.Widget).setMarginStart(12);
        content.as(gtk.Widget).setMarginEnd(12);

        const box = gtk.Box.new(.vertical, 2);
        box.as(gtk.Widget).setHexpand(1);

        const title = gtk.Label.new(null);
        title.setXalign(0);
        title.as(gtk.Widget).setHexpand(1);
        title.setLabel(workspace_page.getSidebarTitle() orelse "");

        const subtitle = gtk.Label.new(null);
        subtitle.setXalign(0);
        subtitle.as(gtk.Widget).setHexpand(1);
        subtitle.as(gtk.Widget).addCssClass("dim-label");
        subtitle.setLabel(workspace_page.getSidebarSubtitle() orelse "");

        const badge = gtk.Label.new(null);
        badge.as(gtk.Widget).addCssClass("accent");
        badge.as(gtk.Widget).setValign(.center);
        badge.as(gtk.Widget).setVisible(0);

        box.append(title.as(gtk.Widget));
        box.append(subtitle.as(gtk.Widget));
        content.append(box.as(gtk.Widget));
        content.append(badge.as(gtk.Widget));
        row.setChild(content.as(gtk.Widget));

        row.as(gobject.Object).setData("workspace-page", workspace_page);
        row.as(gobject.Object).setData("workspace-badge", badge);
        row.as(gobject.Object).setData("workspace-title-label", title);
        row.as(gobject.Object).setData("workspace-subtitle-label", subtitle);

        const sidebar: *Self = @ptrCast(@alignCast(ud orelse @panic("expected sidebar")));
        const gesture = gtk.GestureClick.new();
        gesture.as(gtk.GestureSingle).setButton(3);
        _ = gtk.GestureClick.signals.released.connect(
            gesture,
            *Self,
            workspaceRowSecondaryClick,
            sidebar,
            .{},
        );
        row.as(gtk.Widget).addController(gesture.as(gtk.EventController));

        return row.as(gtk.Widget);
    }

    fn workspaceRowSecondaryClick(
        gesture: *gtk.GestureClick,
        _: c_int,
        x: f64,
        y: f64,
        self: *Self,
    ) callconv(.c) void {
        const priv = self.private();
        const row_widget = gesture.as(gtk.EventController).getWidget() orelse return;
        const row = gobject.ext.cast(gtk.ListBoxRow, row_widget) orelse return;
        const page_obj = row.as(gobject.Object).getData("workspace-page") orelse return;
        const workspace_page: *WorkspacePage = @ptrCast(@alignCast(page_obj));
        priv.context_workspace_page = workspace_page;

        var list_x: f64 = 0;
        var list_y: f64 = 0;
        if (row.as(gtk.Widget).translateCoordinates(
            priv.workspace_list.as(gtk.Widget),
            x,
            y,
            &list_x,
            &list_y,
        ) == 0) return;

        const rect: gdk.Rectangle = .{
            .f_x = @intFromFloat(list_x),
            .f_y = @intFromFloat(list_y),
            .f_width = 1,
            .f_height = 1,
        };
        self.ensureContextMenuPopover();
        if (priv.context_menu_popover.?.as(gtk.Widget).isVisible() != 0) {
            priv.context_menu_popover.?.setPointingTo(&rect);
            return;
        }

        self.showContextMenu(rect);
    }

    fn workspaceListSecondaryClick(
        _: *gtk.GestureClick,
        _: c_int,
        x: f64,
        y: f64,
        self: *Self,
    ) callconv(.c) void {
        const priv = self.private();
        if (priv.workspace_list.getRowAtY(@intFromFloat(y)) != null) return;

        const rect: gdk.Rectangle = .{
            .f_x = @intFromFloat(x),
            .f_y = @intFromFloat(y),
            .f_width = 1,
            .f_height = 1,
        };
        self.ensureEmptyContextMenuPopover();
        if (priv.workspace_empty_context_popover.?.as(gtk.Widget).isVisible() != 0) {
            priv.pending_workspace_empty_restore = false;
            priv.workspace_empty_context_popover.?.setPointingTo(&rect);
            return;
        }

        self.showEmptyContextMenu(rect);
    }

    fn ensureContextMenuPopover(self: *Self) void {
        const priv = self.private();
        if (priv.context_menu_popover != null) return;
        const content = gtk.Box.new(.vertical, 0);
        const descriptors = [_]WorkspaceContextActionDescriptor{
            .{ .label = i18n._("Rename Workspace…"), .action = .rename },
            .{ .label = i18n._("Save Workspace"), .action = .save },
            .{ .label = i18n._("Restore Workspace Here…"), .action = .restore },
            .{ .label = i18n._("Reveal Snapshot"), .action = .reveal },
            .{ .label = i18n._("Open Snapshot File…"), .action = .open_file },
            .{ .label = i18n._("Delete Saved Workspace"), .action = .delete_saved, .destructive = true },
            .{ .label = i18n._("Close Workspace"), .action = .close, .destructive = true },
        };
        inline for (descriptors) |descriptor| {
            content.append(createContextActionButton(self, descriptor).as(gtk.Widget));
        }

        const popover = gtk.Popover.new();
        popover.setHasArrow(0);
        popover.setChild(content.as(gtk.Widget));
        popover.as(gtk.Widget).setParent(priv.workspace_list.as(gtk.Widget));
        _ = gtk.Popover.signals.closed.connect(popover, *Self, workspaceRowContextMenuClosed, self, .{});

        priv.context_menu_popover = popover;
    }

    fn ensureEmptyContextMenuPopover(self: *Self) void {
        const priv = self.private();
        if (priv.workspace_empty_context_popover != null) return;

        const content = gtk.Box.new(.vertical, 0);
        const restore_button = gtk.Button.newWithLabel(i18n._("Restore Workspace…"));
        restore_button.as(gtk.Widget).setHalign(.fill);
        _ = gtk.Button.signals.clicked.connect(restore_button, *Self, workspaceEmptyRestoreClicked, self, .{});
        content.append(restore_button.as(gtk.Widget));

        const popover = gtk.Popover.new();
        popover.setHasArrow(0);
        popover.setChild(content.as(gtk.Widget));
        popover.as(gtk.Widget).setParent(priv.workspace_list.as(gtk.Widget));
        _ = gtk.Popover.signals.closed.connect(popover, *Self, workspaceEmptyContextMenuClosed, self, .{});

        priv.workspace_empty_context_popover = popover;
    }

    fn showContextMenu(self: *Self, rect: gdk.Rectangle) void {
        const priv = self.private();
        self.ensureContextMenuPopover();
        priv.context_menu_popover.?.setPointingTo(&rect);
        priv.context_menu_popover.?.popup();
    }

    fn showEmptyContextMenu(self: *Self, rect: gdk.Rectangle) void {
        const priv = self.private();
        self.ensureEmptyContextMenuPopover();
        priv.workspace_empty_context_popover.?.setPointingTo(&rect);
        priv.workspace_empty_context_popover.?.popup();
    }

    fn createContextActionButton(
        self: *Self,
        descriptor: WorkspaceContextActionDescriptor,
    ) *gtk.Button {
        const button = gtk.Button.newWithLabel(descriptor.label);
        button.as(gtk.Widget).setHalign(.fill);
        if (descriptor.destructive) button.as(gtk.Widget).addCssClass("destructive-action");
        button.as(gobject.Object).setData(
            "workspace-context-action",
            @ptrFromInt(@intFromEnum(descriptor.action) + 1),
        );
        _ = gtk.Button.signals.clicked.connect(button, *Self, workspaceRowActionClicked, self, .{});
        return button;
    }

    fn workspaceRowActionClicked(button: *gtk.Button, self: *Self) callconv(.c) void {
        const action_ptr = button.as(gobject.Object).getData("workspace-context-action") orelse return;
        const action: WorkspaceContextAction = @enumFromInt(@intFromPtr(action_ptr) - 1);
        self.queueContextAction(button, action);
    }

    fn workspaceEmptyRestoreClicked(button: *gtk.Button, self: *Self) callconv(.c) void {
        const priv = self.private();
        priv.pending_workspace_empty_restore = true;
        if (ext.getAncestor(gtk.Popover, button.as(gtk.Widget))) |popover| popover.popdown();
    }

    fn queueContextAction(self: *Self, button: *gtk.Button, action: WorkspaceContextAction) void {
        const priv = self.private();
        const workspace_page = priv.context_workspace_page orelse return;
        if (priv.pending_context_workspace_page) |old_page| old_page.unref();
        priv.pending_context_workspace_page = workspace_page.ref();
        priv.pending_context_workspace_action = action;
        if (ext.getAncestor(gtk.Popover, button.as(gtk.Widget))) |popover| popover.popdown();
    }

    fn workspaceRowContextMenuClosed(_: *gtk.Popover, self: *Self) callconv(.c) void {
        const priv = self.private();
        if (priv.pending_context_workspace_page) |workspace_page| {
            const action = priv.pending_context_workspace_action orelse .rename;
            priv.pending_context_workspace_page = null;
            priv.pending_context_workspace_action = null;

            const ctx = IdleWorkspaceActionContext.new(self, workspace_page, action) catch |err| {
                workspace_page.unref();
                log.err("failed to allocate pending workspace action context err={}", .{err});
                return;
            };
            priv.pending_context_action_ctx = ctx;
            const source = glib.idleAdd(idleEmitPendingWorkspaceAction, ctx);
            if (source == 0) {
                priv.pending_context_action_ctx = null;
                ctx.deinit();
                log.err("failed to schedule pending workspace action", .{});
                return;
            }
            priv.pending_context_action_source = source;
        }
    }

    fn workspaceEmptyContextMenuClosed(_: *gtk.Popover, self: *Self) callconv(.c) void {
        const priv = self.private();
        if (!priv.pending_workspace_empty_restore) return;
        priv.pending_workspace_empty_restore = false;
        const sidebar = self.ref();
        const source = glib.idleAdd(idleEmitRestoreWorkspace, sidebar);
        if (source == 0) {
            sidebar.unref();
            log.err("failed to schedule workspace restore action", .{});
            return;
        }
        priv.pending_restore_source = source;
    }

    fn workspaceListRowSelected(_: *gtk.ListBox, row_: ?*gtk.ListBoxRow, self: *Self) callconv(.c) void {
        const row = row_ orelse return;
        const page_obj = row.as(gobject.Object).getData("workspace-page") orelse return;
        const workspace_page: *WorkspacePage = @ptrCast(@alignCast(page_obj));
        signals.@"workspace-selected".impl.emit(self, null, .{workspace_page}, null);
    }

    fn newWorkspaceClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        signals.@"new-workspace".impl.emit(self, null, .{}, null);
    }

    const IdleWorkspaceActionContext = struct {
        alloc: std.mem.Allocator,
        sidebar: *Self,
        workspace_page: *WorkspacePage,
        action: WorkspaceContextAction,

        fn new(
            sidebar: *Self,
            workspace_page: *WorkspacePage,
            action: WorkspaceContextAction,
        ) std.mem.Allocator.Error!*IdleWorkspaceActionContext {
            const alloc = workspaceActionAllocator();
            const ctx = try alloc.create(IdleWorkspaceActionContext);
            ctx.* = .{
                .alloc = alloc,
                .sidebar = sidebar.ref(),
                .workspace_page = workspace_page,
                .action = action,
            };
            return ctx;
        }

        fn deinit(self: *IdleWorkspaceActionContext) void {
            const alloc = self.alloc;
            self.workspace_page.unref();
            self.sidebar.unref();
            alloc.destroy(self);
        }
    };

    fn workspaceActionAllocator() std.mem.Allocator {
        const app = gio.Application.getDefault() orelse return std.heap.page_allocator;
        const ghostty_app = gobject.ext.cast(Application, app) orelse return std.heap.page_allocator;
        return ghostty_app.allocator();
    }

    fn idleEmitPendingWorkspaceAction(ud: ?*anyopaque) callconv(.c) c_int {
        const ctx: *IdleWorkspaceActionContext = @ptrCast(@alignCast(ud orelse return 0));
        defer ctx.deinit();
        const priv = ctx.sidebar.private();
        if (priv.pending_context_action_ctx == ctx) {
            priv.pending_context_action_ctx = null;
            priv.pending_context_action_source = null;
        }
        switch (ctx.action) {
            .rename => signals.@"prompt-workspace-title".impl.emit(ctx.sidebar, null, .{ctx.workspace_page}, null),
            .save => signals.@"save-workspace".impl.emit(ctx.sidebar, null, .{ctx.workspace_page}, null),
            .restore => signals.@"restore-workspace-and-close".impl.emit(ctx.sidebar, null, .{ctx.workspace_page}, null),
            .delete_saved => signals.@"delete-workspace".impl.emit(ctx.sidebar, null, .{ctx.workspace_page}, null),
            .open_file => signals.@"open-workspace-snapshot".impl.emit(ctx.sidebar, null, .{ctx.workspace_page}, null),
            .reveal => signals.@"reveal-workspace-snapshot".impl.emit(ctx.sidebar, null, .{ctx.workspace_page}, null),
            .close => signals.@"close-workspace".impl.emit(ctx.sidebar, null, .{ctx.workspace_page}, null),
        }
        return 0;
    }

    fn idleEmitRestoreWorkspace(ud: ?*anyopaque) callconv(.c) c_int {
        const self: *Self = @ptrCast(@alignCast(ud orelse return 0));
        defer self.unref();
        self.private().pending_restore_source = null;
        signals.@"restore-workspace".impl.emit(self, null, .{}, null);
        return 0;
    }

    fn dispose(self: *Self) callconv(.c) void {
        const priv = self.private();
        priv.disposing = true;
        if (priv.pending_context_action_source) |source| {
            _ = glib.Source.remove(source);
            priv.pending_context_action_source = null;
        }
        if (priv.pending_context_action_ctx) |ctx| {
            priv.pending_context_action_ctx = null;
            ctx.deinit();
        }
        if (priv.pending_restore_source) |source| {
            _ = glib.Source.remove(source);
            priv.pending_restore_source = null;
            self.unref();
        }
        priv.context_workspace_page = null;
        if (priv.context_menu_popover) |popover| {
            _ = gobject.signalHandlersDisconnectMatched(
                popover.as(gobject.Object),
                .{ .data = true },
                0,
                0,
                null,
                null,
                self,
            );
            popover.popdown();
            popover.setChild(null);
            if (popover.as(gtk.Widget).getParent() != null) {
                popover.as(gtk.Widget).unparent();
            }
            priv.context_menu_popover = null;
        }
        if (priv.workspace_empty_context_popover) |popover| {
            _ = gobject.signalHandlersDisconnectMatched(
                popover.as(gobject.Object),
                .{ .data = true },
                0,
                0,
                null,
                null,
                self,
            );
            popover.popdown();
            popover.setChild(null);
            if (popover.as(gtk.Widget).getParent() != null) {
                popover.as(gtk.Widget).unparent();
            }
            priv.workspace_empty_context_popover = null;
        }
        if (priv.pending_context_workspace_page) |workspace_page| {
            workspace_page.unref();
            priv.pending_context_workspace_page = null;
        }
        gtk.Widget.disposeTemplate(
            self.as(gtk.Widget),
            getGObjectType(),
        );
        gobject.Object.virtual_methods.dispose.call(Class.parent, self.as(Parent));
    }

    const C = Common(Self, Private);
    pub const as = C.as;
    pub const ref = C.ref;
    pub const refSink = C.refSink;
    pub const unref = C.unref;
    const private = C.private;

    pub const Class = extern struct {
        parent_class: Parent.Class,
        var parent: *Parent.Class = undefined;
        pub const Instance = Self;

        fn init(class: *Class) callconv(.c) void {
            gtk.Widget.Class.setTemplateFromResource(
                class.as(gtk.Widget.Class),
                comptime gresource.blueprint(.{
                    .major = 1,
                    .minor = 5,
                    .name = "workspace-sidebar",
                }),
            );

            class.bindTemplateChildPrivate("workspace_list", .{});
            class.bindTemplateCallback("workspace_row_selected", &workspaceListRowSelected);
            class.bindTemplateCallback("new_workspace", &newWorkspaceClicked);

            signals.@"workspace-selected".impl.register(.{});
            signals.@"new-workspace".impl.register(.{});
            signals.@"prompt-workspace-title".impl.register(.{});
            signals.@"save-workspace".impl.register(.{});
            signals.@"delete-workspace".impl.register(.{});
            signals.@"reveal-workspace-snapshot".impl.register(.{});
            signals.@"open-workspace-snapshot".impl.register(.{});
            signals.@"close-workspace".impl.register(.{});
            signals.@"restore-workspace".impl.register(.{});
            signals.@"restore-workspace-and-close".impl.register(.{});

            gobject.Object.virtual_methods.dispose.implement(class, &dispose);
        }

        pub const as = C.Class.as;
        pub const bindTemplateChildPrivate = C.Class.bindTemplateChildPrivate;
        pub const bindTemplateCallback = C.Class.bindTemplateCallback;
    };
};

test "workspace sidebar dispose cancels pending deferred actions" {
    const testing = std.testing;

    if (gtk.initCheck() == 0) return error.SkipZigTest;

    gobject.ext.ensureType(WorkspaceSidebar);
    gobject.ext.ensureType(WorkspacePage);

    const sidebar = gobject.ext.newInstance(WorkspaceSidebar, .{});
    _ = sidebar.refSink();
    defer sidebar.unref();

    const workspace_page = gobject.ext.newInstance(WorkspacePage, .{});
    _ = workspace_page.refSink();
    defer workspace_page.unref();

    var delete_count: usize = 0;
    var restore_count: usize = 0;
    _ = WorkspaceSidebar.signals.@"delete-workspace".connect(
        sidebar,
        *usize,
        struct {
            fn handler(_: *WorkspaceSidebar, _: *WorkspacePage, count: *usize) callconv(.c) void {
                count.* += 1;
            }
        }.handler,
        &delete_count,
        .{},
    );
    _ = WorkspaceSidebar.signals.@"restore-workspace".connect(
        sidebar,
        *usize,
        struct {
            fn handler(_: *WorkspaceSidebar, count: *usize) callconv(.c) void {
                count.* += 1;
            }
        }.handler,
        &restore_count,
        .{},
    );

    const priv = sidebar.private();
    priv.pending_context_workspace_page = workspace_page.ref();
    priv.pending_context_workspace_action = .delete_saved;
    WorkspaceSidebar.workspaceRowContextMenuClosed(undefined, sidebar);

    priv.pending_workspace_empty_restore = true;
    WorkspaceSidebar.workspaceEmptyContextMenuClosed(undefined, sidebar);

    try testing.expect(priv.pending_context_action_source != null);
    try testing.expect(priv.pending_context_action_ctx != null);
    try testing.expect(priv.pending_restore_source != null);

    WorkspaceSidebar.dispose(sidebar);

    try testing.expect(priv.pending_context_action_source == null);
    try testing.expect(priv.pending_context_action_ctx == null);
    try testing.expect(priv.pending_restore_source == null);
    try testing.expect(priv.pending_context_workspace_page == null);

    while (glib.MainContext.iteration(null, 0) != 0) {}

    try testing.expectEqual(@as(usize, 0), delete_count);
    try testing.expectEqual(@as(usize, 0), restore_count);
}

test "workspace row restore emits close-after-restore target" {
    const testing = std.testing;

    if (gtk.initCheck() == 0) return error.SkipZigTest;

    gobject.ext.ensureType(WorkspaceSidebar);
    gobject.ext.ensureType(WorkspacePage);

    const sidebar = gobject.ext.newInstance(WorkspaceSidebar, .{});
    _ = sidebar.refSink();
    defer sidebar.unref();

    const workspace_page = gobject.ext.newInstance(WorkspacePage, .{});
    _ = workspace_page.refSink();
    defer workspace_page.unref();

    var capture: struct {
        restored_page: ?*WorkspacePage = null,
    } = .{};
    _ = WorkspaceSidebar.signals.@"restore-workspace-and-close".connect(
        sidebar,
        @TypeOf(&capture),
        struct {
            fn handler(
                _: *WorkspaceSidebar,
                close_after_restore: *WorkspacePage,
                result: @TypeOf(&capture),
            ) callconv(.c) void {
                result.restored_page = close_after_restore;
            }
        }.handler,
        &capture,
        .{},
    );

    const priv = sidebar.private();
    priv.pending_context_workspace_page = workspace_page.ref();
    priv.pending_context_workspace_action = .restore;
    WorkspaceSidebar.workspaceRowContextMenuClosed(undefined, sidebar);

    while (priv.pending_context_action_source != null) {
        _ = glib.MainContext.iteration(null, 1);
    }

    try testing.expectEqual(workspace_page, capture.restored_page.?);
}
