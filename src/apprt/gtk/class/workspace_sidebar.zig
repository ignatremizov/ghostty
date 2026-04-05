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
const WorkspacePage = @import("workspace_page.zig").WorkspacePage;

const WorkspaceContextAction = enum {
    rename,
    save,
    open_file,
    reveal,
    close,
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
    };

    const Private = struct {
        disposing: bool = false,
        context_menu_popover: ?*gtk.Popover = null,
        workspace_empty_context_popover: ?*gtk.Popover = null,
        context_workspace_page: ?*WorkspacePage = null,
        pending_context_workspace_page: ?*WorkspacePage = null,
        pending_context_workspace_action: ?WorkspaceContextAction = null,
        pending_workspace_empty_restore: bool = false,

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
            selected.tab_title,
            selected.session_title,
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

        const rename_button = gtk.Button.newWithLabel(i18n._("Change Workspace Title…"));
        rename_button.as(gtk.Widget).setHalign(.fill);
        _ = gtk.Button.signals.clicked.connect(rename_button, *Self, workspaceRowRenameClicked, self, .{});

        const save_button = gtk.Button.newWithLabel(i18n._("Save Workspace"));
        save_button.as(gtk.Widget).setHalign(.fill);
        _ = gtk.Button.signals.clicked.connect(save_button, *Self, workspaceRowSaveClicked, self, .{});

        const reveal_button = gtk.Button.newWithLabel(i18n._("Reveal Snapshot"));
        reveal_button.as(gtk.Widget).setHalign(.fill);
        _ = gtk.Button.signals.clicked.connect(reveal_button, *Self, workspaceRowRevealClicked, self, .{});

        const open_button = gtk.Button.newWithLabel(i18n._("Open Snapshot File…"));
        open_button.as(gtk.Widget).setHalign(.fill);
        _ = gtk.Button.signals.clicked.connect(open_button, *Self, workspaceRowOpenSnapshotClicked, self, .{});

        const close_button = gtk.Button.newWithLabel(i18n._("Close Workspace"));
        close_button.as(gtk.Widget).setHalign(.fill);
        close_button.as(gtk.Widget).addCssClass("destructive-action");
        _ = gtk.Button.signals.clicked.connect(close_button, *Self, workspaceRowCloseClicked, self, .{});

        content.append(rename_button.as(gtk.Widget));
        content.append(save_button.as(gtk.Widget));
        content.append(reveal_button.as(gtk.Widget));
        content.append(open_button.as(gtk.Widget));
        content.append(close_button.as(gtk.Widget));

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

    fn workspaceRowRenameClicked(button: *gtk.Button, self: *Self) callconv(.c) void {
        self.queueContextAction(button, .rename);
    }
    fn workspaceRowSaveClicked(button: *gtk.Button, self: *Self) callconv(.c) void {
        self.queueContextAction(button, .save);
    }
    fn workspaceRowRevealClicked(button: *gtk.Button, self: *Self) callconv(.c) void {
        self.queueContextAction(button, .reveal);
    }
    fn workspaceRowOpenSnapshotClicked(button: *gtk.Button, self: *Self) callconv(.c) void {
        self.queueContextAction(button, .open_file);
    }
    fn workspaceRowCloseClicked(button: *gtk.Button, self: *Self) callconv(.c) void {
        self.queueContextAction(button, .close);
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
            _ = glib.idleAdd(idleEmitPendingWorkspaceAction, IdleWorkspaceActionContext.new(self.ref(), workspace_page, action));
            priv.pending_context_workspace_page = null;
            priv.pending_context_workspace_action = null;
        }
    }

    fn workspaceEmptyContextMenuClosed(_: *gtk.Popover, self: *Self) callconv(.c) void {
        const priv = self.private();
        if (!priv.pending_workspace_empty_restore) return;
        priv.pending_workspace_empty_restore = false;
        _ = glib.idleAdd(idleEmitRestoreWorkspace, self.ref());
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
        sidebar: *Self,
        workspace_page: *WorkspacePage,
        action: WorkspaceContextAction,

        fn new(sidebar: *Self, workspace_page: *WorkspacePage, action: WorkspaceContextAction) *IdleWorkspaceActionContext {
            const alloc = std.heap.c_allocator;
            const ctx = alloc.create(IdleWorkspaceActionContext) catch @panic("oom");
            ctx.* = .{ .sidebar = sidebar, .workspace_page = workspace_page, .action = action };
            return ctx;
        }

        fn deinit(self: *IdleWorkspaceActionContext) void {
            self.workspace_page.unref();
            self.sidebar.unref();
            std.heap.c_allocator.destroy(self);
        }
    };

    fn idleEmitPendingWorkspaceAction(ud: ?*anyopaque) callconv(.c) c_int {
        const ctx: *IdleWorkspaceActionContext = @ptrCast(@alignCast(ud orelse return 0));
        defer ctx.deinit();
        switch (ctx.action) {
            .rename => signals.@"prompt-workspace-title".impl.emit(ctx.sidebar, null, .{ctx.workspace_page}, null),
            .save => signals.@"save-workspace".impl.emit(ctx.sidebar, null, .{ctx.workspace_page}, null),
            .open_file => signals.@"open-workspace-snapshot".impl.emit(ctx.sidebar, null, .{ctx.workspace_page}, null),
            .reveal => signals.@"reveal-workspace-snapshot".impl.emit(ctx.sidebar, null, .{ctx.workspace_page}, null),
            .close => signals.@"close-workspace".impl.emit(ctx.sidebar, null, .{ctx.workspace_page}, null),
        }
        return 0;
    }

    fn idleEmitRestoreWorkspace(ud: ?*anyopaque) callconv(.c) c_int {
        const self: *Self = @ptrCast(@alignCast(ud orelse return 0));
        defer self.unref();
        signals.@"restore-workspace".impl.emit(self, null, .{}, null);
        return 0;
    }

    fn dispose(self: *Self) callconv(.c) void {
        const priv = self.private();
        priv.disposing = true;
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
            signals.@"reveal-workspace-snapshot".impl.register(.{});
            signals.@"open-workspace-snapshot".impl.register(.{});
            signals.@"close-workspace".impl.register(.{});
            signals.@"restore-workspace".impl.register(.{});

            gobject.Object.virtual_methods.dispose.implement(class, &dispose);
        }

        pub const as = C.Class.as;
        pub const bindTemplateChildPrivate = C.Class.bindTemplateChildPrivate;
        pub const bindTemplateCallback = C.Class.bindTemplateCallback;
    };
};
