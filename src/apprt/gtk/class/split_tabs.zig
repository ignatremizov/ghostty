const std = @import("std");
const adw = @import("adw");
const gdk = @import("gdk");
const gio = @import("gio");
const glib = @import("glib");
const gobject = @import("gobject");
const gtk = @import("gtk");

const apprt = @import("../../../apprt.zig");
const configpkg = @import("../../../config.zig");
const datastruct = @import("../../../datastruct/main.zig");
const Common = @import("../class.zig").Common;
const ext = @import("../ext.zig");
const gresource = @import("../build/gresource.zig");
const Application = @import("application.zig").Application;
const CloseConfirmationDialog = @import("close_confirmation_dialog.zig").CloseConfirmationDialog;
const Surface = @import("surface.zig").Surface;
const Tab = @import("tab.zig").Tab;

const log = std.log.scoped(.gtk_ghostty_split_tabs);

pub const SplitTabs = extern struct {
    const Self = @This();
    parent_instance: Parent,
    pub const Parent = gtk.Box;
    pub const Tree = datastruct.SplitTree(Self);
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "GhosttySplitTabs",
        .instanceInit = &init,
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    pub const SelectTab = union(enum) {
        previous,
        next,
        last,
        n: usize,
    };

    pub const properties = struct {
        pub const @"active-surface" = struct {
            pub const name = "active-surface";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                ?*Surface,
                .{
                    .accessor = gobject.ext.typedAccessor(
                        Self,
                        ?*Surface,
                        .{ .getter = getActiveSurface },
                    ),
                },
            );
        };

        pub const @"has-surfaces" = struct {
            pub const name = "has-surfaces";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                bool,
                .{
                    .default = false,
                    .accessor = gobject.ext.typedAccessor(
                        Self,
                        bool,
                        .{ .getter = getHasSurfaces },
                    ),
                },
            );
        };
    };

    pub const signals = struct {
        pub const @"surface-added" = struct {
            pub const name = "surface-added";
            pub const connect = impl.connect;
            const impl = gobject.ext.defineSignal(name, Self, &.{*Surface}, void);
        };

        pub const @"surface-removed" = struct {
            pub const name = "surface-removed";
            pub const connect = impl.connect;
            const impl = gobject.ext.defineSignal(name, Self, &.{*Surface}, void);
        };
    };

    const Private = struct {
        disposing: bool = false,
        pending_close_page: ?*adw.TabPage = null,
        context_menu_tab: ?*Tab = null,
        context_menu_popover: ?*gtk.Popover = null,
        pending_context_menu_rect: ?gdk.Rectangle = null,
        pending_prompt_tab: ?*Tab = null,
        tab_bar: *adw.TabBar,
        tab_view: *adw.TabView,
        pub var offset: c_int = 0;
    };

    pub fn new(surface: *Surface) *Self {
        const self = gobject.ext.newInstance(Self, .{});
        _ = self.addSurface(surface, true);
        return self;
    }

    fn init(self: *Self, _: *Class) callconv(.c) void {
        gtk.Widget.initTemplate(self.as(gtk.Widget));
        const gesture = gtk.GestureClick.new();
        gesture.as(gtk.GestureSingle).setButton(3);
        gesture.as(gtk.EventController).setPropagationPhase(.capture);
        _ = gtk.GestureClick.signals.released.connect(
            gesture,
            *Self,
            tabBarSecondaryClick,
            self,
            .{},
        );
        self.private().tab_bar.as(gtk.Widget).addController(gesture.as(gtk.EventController));
    }

    pub fn getHasSurfaces(self: *Self) bool {
        if (self.private().disposing) return false;
        return self.private().tab_view.getNPages() > 0;
    }

    pub fn getFocused(self: *Self) bool {
        const surface = self.getActiveSurface() orelse return false;
        return surface.getFocused();
    }

    pub fn grabFocus(self: *Self) void {
        const surface = self.getActiveSurface() orelse return;
        surface.grabFocus();
    }

    pub fn splitTreeLabel(self: *Self) [:0]const u8 {
        const surface = self.getActiveSurface() orelse return "tab";
        return surface.getEffectiveTitle() orelse "tab";
    }

    pub fn getNeedsConfirmQuit(self: *Self) bool {
        const n = self.private().tab_view.getNPages();
        for (0..@intCast(n)) |i| {
            const surface = self.getSurfaceAt(@intCast(i)) orelse continue;
            const core = surface.core() orelse continue;
            if (core.needsConfirmQuit()) return true;
        }
        return false;
    }

    pub fn getActiveSurface(self: *Self) ?*Surface {
        if (self.private().disposing) return null;
        const page = self.private().tab_view.getSelectedPage() orelse {
            if (self.private().tab_view.getNPages() == 0) return null;
            return self.getSurfaceAt(0);
        };
        return self.getPageSurface(page);
    }

    pub fn getSurfaceAt(self: *Self, idx: c_int) ?*Surface {
        const page = self.private().tab_view.getNthPage(idx);
        return self.getPageSurface(page);
    }

    pub fn getSurfaceCount(self: *Self) c_int {
        return self.private().tab_view.getNPages();
    }

    pub fn redraw(self: *Self) void {
        const n = self.getSurfaceCount();
        for (0..@intCast(n)) |i| {
            const surface = self.getSurfaceAt(@intCast(i)) orelse continue;
            surface.redraw();
        }
    }

    fn getPageSurface(self: *Self, page: *adw.TabPage) ?*Surface {
        _ = self;
        const child = page.getChild();
        const tab = gobject.ext.cast(Tab, child) orelse return null;
        return tab.getSurface();
    }

    fn getPageForSurface(self: *Self, surface: *Surface) ?*adw.TabPage {
        const n = self.private().tab_view.getNPages();
        for (0..@intCast(n)) |i| {
            const page = self.private().tab_view.getNthPage(@intCast(i));
            if (self.getPageSurface(page) == surface) return page;
        }
        return null;
    }

    pub fn containsSurface(self: *Self, surface: *Surface) bool {
        return self.getPageForSurface(surface) != null;
    }

    pub fn addSurface(self: *Self, surface: *Surface, select: bool) *adw.TabPage {
        const priv = self.private();
        const tab = Tab.new(surface);
        const page = priv.tab_view.append(tab.as(gtk.Widget));

        _ = tab.as(gobject.Object).bindProperty(
            "title",
            page.as(gobject.Object),
            "title",
            .{ .sync_create = true },
        );
        _ = tab.as(gobject.Object).bindProperty(
            "tooltip",
            page.as(gobject.Object),
            "tooltip",
            .{ .sync_create = true },
        );

        if (select) {
            priv.tab_view.setSelectedPage(page);
        }

        self.as(gobject.Object).notifyByPspec(properties.@"has-surfaces".impl.param_spec);
        self.as(gobject.Object).notifyByPspec(properties.@"active-surface".impl.param_spec);
        signals.@"surface-added".impl.emit(self, null, .{surface}, null);
        return page;
    }

    pub fn newTab(
        self: *Self,
        parent_: ?*Surface,
        overrides: struct {
            command: ?configpkg.Command = null,
            working_directory: ?[:0]const u8 = null,
            title: ?[:0]const u8 = null,

            pub const none: @This() = .{};
        },
    ) std.mem.Allocator.Error!*Surface {
        const surface: *Surface = .new(.{
            .command = overrides.command,
            .working_directory = overrides.working_directory,
            .title = overrides.title,
        });
        errdefer surface.unref();
        _ = surface.refSink();
        defer surface.unref();

        if (parent_) |parent| {
            if (parent.core()) |core| {
                surface.setParent(core, .tab);
            }
        }

        _ = self.addSurface(surface, true);
        return surface;
    }

    pub fn removeSurface(self: *Self, surface: *Surface) bool {
        const page = self.getPageForSurface(surface) orelse return false;
        self.private().tab_view.closePage(page);
        return true;
    }

    pub fn closeSurface(
        self: *Self,
        surface: *Surface,
        mode: apprt.action.CloseTabMode,
    ) bool {
        const page = self.getPageForSurface(surface) orelse return false;
        const page_view = self.private().tab_view;
        switch (mode) {
            .this => page_view.closePage(page),
            .other => page_view.closeOtherPages(page),
            .right => page_view.closePagesAfter(page),
        }
        return true;
    }

    pub fn selectTab(self: *Self, n: SelectTab) bool {
        const page_view = self.private().tab_view;
        const selected = page_view.getSelectedPage() orelse return false;
        const current = page_view.getPagePosition(selected);
        const total = page_view.getNPages();
        if (total <= 0) return false;

        const goto: c_int = switch (n) {
            .previous => if (current > 0) current - 1 else total - 1,
            .next => if (current < total - 1) current + 1 else 0,
            .last => total - 1,
            .n => |v| n_int: {
                if (v == 0) return false;
                const n_int = std.math.cast(c_int, v) orelse return false;
                break :n_int @min(n_int - 1, total - 1);
            },
        };
        if (goto == current) return false;
        page_view.setSelectedPage(page_view.getNthPage(goto));
        return true;
    }

    pub fn moveSurface(self: *Self, surface: *Surface, amount: isize) bool {
        const page_view = self.private().tab_view;
        const total = page_view.getNPages();
        if (total <= 1) return false;

        const page = self.getPageForSurface(surface) orelse return false;
        const pos = page_view.getPagePosition(page);
        const desired_pos: c_int = desired: {
            const initial: c_int = @intCast(pos + amount);
            const max = total - 1;
            break :desired if (initial < 0)
                max + initial + 1
            else if (initial > max)
                initial - max - 1
            else
                initial;
        };
        if (desired_pos == pos) return false;
        return page_view.reorderPage(page, desired_pos) != 0;
    }

    pub fn promptActiveTabTitle(self: *Self) void {
        const page = self.private().tab_view.getSelectedPage() orelse return;
        const child = page.getChild();
        const tab = gobject.ext.cast(Tab, child) orelse return;
        tab.promptTitle();
    }

    pub fn setActiveTabTitle(self: *Self, title: ?[:0]const u8) bool {
        const page = self.private().tab_view.getSelectedPage() orelse return false;
        const child = page.getChild();
        const tab = gobject.ext.cast(Tab, child) orelse return false;
        tab.setTitleOverride(title);
        return true;
    }

    fn tabViewSelectedPage(_: *adw.TabView, _: *gobject.ParamSpec, self: *Self) callconv(.c) void {
        if (self.private().disposing) return;
        const page = self.private().tab_view.getSelectedPage() orelse {
            self.as(gobject.Object).notifyByPspec(properties.@"active-surface".impl.param_spec);
            return;
        };
        page.setNeedsAttention(@intFromBool(false));
        const surface = self.getPageSurface(page) orelse return;
        surface.grabFocus();
        self.as(gobject.Object).notifyByPspec(properties.@"active-surface".impl.param_spec);
    }

    fn tabViewClosePage(_: *adw.TabView, page: *adw.TabPage, self: *Self) callconv(.c) c_int {
        if (self.private().disposing) return @intFromBool(false);
        const child = page.getChild();
        const tab = gobject.ext.cast(Tab, child) orelse return @intFromBool(false);

        if (!tab.getNeedsConfirmQuit()) {
            self.private().tab_view.closePageFinish(page, @intFromBool(true));
            return @intFromBool(true);
        }

        const dialog: *CloseConfirmationDialog = .new(.tab);
        _ = CloseConfirmationDialog.signals.@"close-request".connect(
            dialog,
            *Self,
            confirmClosePage,
            self,
            .{},
        );
        _ = CloseConfirmationDialog.signals.cancel.connect(
            dialog,
            *Self,
            cancelClosePage,
            self,
            .{},
        );
        self.private().pending_close_page = page;
        dialog.present(child);
        return @intFromBool(true);
    }

    fn confirmClosePage(_: *CloseConfirmationDialog, self: *Self) callconv(.c) void {
        const page = self.private().pending_close_page orelse return;
        self.private().pending_close_page = null;
        self.private().tab_view.closePageFinish(page, @intFromBool(true));
    }

    fn cancelClosePage(_: *CloseConfirmationDialog, self: *Self) callconv(.c) void {
        const page = self.private().pending_close_page orelse return;
        self.private().pending_close_page = null;
        self.private().tab_view.closePageFinish(page, @intFromBool(false));
    }

    fn tabViewPageDetached(_: *adw.TabView, page: *adw.TabPage, _: c_int, self: *Self) callconv(.c) void {
        if (self.private().disposing) return;
        if (self.getPageSurface(page)) |surface| {
            signals.@"surface-removed".impl.emit(self, null, .{surface}, null);
        }
        self.as(gobject.Object).notifyByPspec(properties.@"has-surfaces".impl.param_spec);
        self.as(gobject.Object).notifyByPspec(properties.@"active-surface".impl.param_spec);
    }

    fn tabBarSecondaryClick(
        gesture: *gtk.GestureClick,
        _: c_int,
        x: f64,
        y: f64,
        self: *Self,
    ) callconv(.c) void {
        const priv = self.private();
        _ = gesture;
        const page = priv.tab_view.getSelectedPage() orelse return;
        const child = page.getChild();
        const tab = gobject.ext.cast(Tab, child) orelse return;
        priv.context_menu_tab = tab;

        const rect: gdk.Rectangle = .{
            .f_x = @intFromFloat(x),
            .f_y = @intFromFloat(y),
            .f_width = 1,
            .f_height = 1,
        };
        self.ensureContextMenuPopover();
        if (priv.context_menu_popover.?.as(gtk.Widget).isVisible() != 0) {
            priv.pending_context_menu_rect = null;
            priv.context_menu_popover.?.setPointingTo(&rect);
            return;
        }

        self.showContextMenu(rect);
    }

    fn ensureContextMenuPopover(self: *Self) void {
        const priv = self.private();
        if (priv.context_menu_popover != null) return;

        const rename_button = gtk.Button.newWithLabel("Change Tab Title…");
        rename_button.as(gtk.Widget).setHalign(.fill);
        _ = gtk.Button.signals.clicked.connect(
            rename_button,
            *Self,
            tabBarRenameClicked,
            self,
            .{},
        );

        const popover = gtk.Popover.new();
        popover.setHasArrow(0);
        popover.setChild(rename_button.as(gtk.Widget));
        popover.as(gtk.Widget).setParent(priv.tab_bar.as(gtk.Widget));
        _ = gtk.Popover.signals.closed.connect(
            popover,
            *Self,
            tabBarContextMenuClosed,
            self,
            .{},
        );

        priv.context_menu_popover = popover;
    }

    fn showContextMenu(self: *Self, rect: gdk.Rectangle) void {
        const priv = self.private();
        self.ensureContextMenuPopover();
        priv.context_menu_popover.?.setPointingTo(&rect);
        priv.context_menu_popover.?.popup();
    }

    fn tabBarRenameClicked(button: *gtk.Button, self: *Self) callconv(.c) void {
        const priv = self.private();
        const tab = priv.context_menu_tab orelse return;
        if (priv.pending_prompt_tab) |old_tab| old_tab.unref();
        priv.pending_prompt_tab = tab.ref();
        if (ext.getAncestor(gtk.Popover, button.as(gtk.Widget))) |popover| {
            popover.popdown();
        }
    }

    fn tabBarContextMenuClosed(popover: *gtk.Popover, self: *Self) callconv(.c) void {
        _ = popover;
        const priv = self.private();
        priv.context_menu_tab = null;
        if (priv.pending_prompt_tab) |tab| {
            priv.pending_prompt_tab = null;
            _ = glib.idleAdd(idlePromptTabTitle, tab);
        }
    }

    fn idlePromptTabTitle(ud: ?*anyopaque) callconv(.c) c_int {
        const tab: *Tab = @ptrCast(@alignCast(ud orelse return 0));
        defer tab.unref();
        tab.promptTitle();
        return 0;
    }

    fn dispose(self: *Self) callconv(.c) void {
        const priv = self.private();
        priv.disposing = true;
        priv.pending_close_page = null;
        priv.context_menu_tab = null;
        if (priv.context_menu_popover) |popover| {
            popover.popdown();
            popover.as(gtk.Widget).unparent();
            priv.context_menu_popover = null;
        }
        priv.pending_context_menu_rect = null;
        if (priv.pending_prompt_tab) |tab| {
            tab.unref();
            priv.pending_prompt_tab = null;
        }
        _ = gobject.signalHandlersDisconnectMatched(
            priv.tab_view.as(gobject.Object),
            .{ .data = true },
            0,
            0,
            null,
            null,
            self,
        );
        gtk.Widget.disposeTemplate(self.as(gtk.Widget), getGObjectType());
        gobject.Object.virtual_methods.dispose.call(Class.parent, self.as(Parent));
    }

    fn finalize(self: *Self) callconv(.c) void {
        gobject.Object.virtual_methods.finalize.call(Class.parent, self.as(Parent));
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
            gobject.ext.ensureType(Tab);
            gtk.Widget.Class.setTemplateFromResource(
                class.as(gtk.Widget.Class),
                comptime gresource.blueprint(.{
                    .major = 1,
                    .minor = 5,
                    .name = "split-tabs",
                }),
            );

            gobject.ext.registerProperties(class, &.{
                properties.@"active-surface".impl,
                properties.@"has-surfaces".impl,
            });

            class.bindTemplateChildPrivate("tab_bar", .{});
            class.bindTemplateChildPrivate("tab_view", .{});
            class.bindTemplateCallback("close_page", &tabViewClosePage);
            class.bindTemplateCallback("notify_selected_page", &tabViewSelectedPage);
            class.bindTemplateCallback("page_detached", &tabViewPageDetached);
            signals.@"surface-added".impl.register(.{});
            signals.@"surface-removed".impl.register(.{});

            gobject.Object.virtual_methods.dispose.implement(class, &dispose);
            gobject.Object.virtual_methods.finalize.implement(class, &finalize);
        }

        pub const as = C.Class.as;
        pub const bindTemplateChildPrivate = C.Class.bindTemplateChildPrivate;
        pub const bindTemplateCallback = C.Class.bindTemplateCallback;
    };
};
