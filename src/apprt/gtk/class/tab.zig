const std = @import("std");
const adw = @import("adw");
const gio = @import("gio");
const glib = @import("glib");
const gobject = @import("gobject");
const gtk = @import("gtk");

const Common = @import("../class.zig").Common;
const ext = @import("../ext.zig");
const gresource = @import("../build/gresource.zig");
const Application = @import("application.zig").Application;
const Surface = @import("surface.zig").Surface;
const SurfaceScrolledWindow = @import("surface_scrolled_window.zig").SurfaceScrolledWindow;
const TitleDialog = @import("title_dialog.zig").TitleDialog;

const log = std.log.scoped(.gtk_ghostty_tab);

pub const Tab = extern struct {
    const Self = @This();
    parent_instance: Parent,
    pub const Parent = gtk.Box;
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "GhosttyTab",
        .instanceInit = &init,
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    pub const properties = struct {
        pub const surface = struct {
            pub const name = "surface";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                ?*Surface,
                .{
                    .accessor = .{
                        .getter = getSurfaceValue,
                        .setter = setSurfaceValue,
                    },
                },
            );
        };

        pub const title = struct {
            pub const name = "title";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                ?[:0]const u8,
                .{
                    .default = null,
                    .accessor = C.privateStringFieldAccessor("title"),
                },
            );
        };

        pub const tooltip = struct {
            pub const name = "tooltip";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                ?[:0]const u8,
                .{
                    .default = null,
                    .accessor = C.privateStringFieldAccessor("tooltip"),
                },
            );
        };

        pub const @"title-override" = struct {
            pub const name = "title-override";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                ?[:0]const u8,
                .{
                    .default = null,
                    .accessor = C.privateStringFieldAccessor("title_override"),
                },
            );
        };
    };

    const Private = struct {
        surface: ?*Surface = null,
        title: ?[:0]const u8 = null,
        tooltip: ?[:0]const u8 = null,
        title_override: ?[:0]const u8 = null,
        action_group: ?*gio.SimpleActionGroup = null,

        surface_scrolled_window: *SurfaceScrolledWindow,

        pub var offset: c_int = 0;
    };

    pub fn new(surface: *Surface) *Self {
        return gobject.ext.newInstance(Self, .{
            .surface = surface,
        });
    }

    fn init(self: *Self, _: *Class) callconv(.c) void {
        gtk.Widget.initTemplate(self.as(gtk.Widget));
        self.initActionMap();
    }

    fn initActionMap(self: *Self) void {
        const actions = [_]ext.actions.Action(Self){
            .init("prompt-tab-title", actionPromptTabTitle, null),
            .init("ring-bell", actionRingBell, null),
        };

        self.private().action_group = ext.actions.addAsGroup(Self, self, "tab", &actions);
    }

    pub fn getSurface(self: *Self) ?*Surface {
        return self.private().surface;
    }

    pub fn getTitleOverride(self: *Self) ?[:0]const u8 {
        return self.private().title_override;
    }

    pub fn getEffectiveTitle(self: *Self) ?[:0]const u8 {
        const priv = self.private();
        return priv.title_override orelse priv.title;
    }

    pub fn getTooltip(self: *Self) ?[:0]const u8 {
        return self.private().tooltip;
    }

    fn getSurfaceValue(self: *Self, value: *gobject.Value) void {
        gobject.ext.Value.set(value, self.private().surface);
    }

    fn setSurfaceValue(self: *Self, value: *const gobject.Value) void {
        self.setSurface(gobject.ext.Value.get(value, ?*Surface));
    }

    pub fn setSurface(self: *Self, surface: ?*Surface) void {
        const priv = self.private();
        if (priv.surface == surface) return;
        priv.surface = surface;
        self.as(gobject.Object).notifyByPspec(properties.surface.impl.param_spec);
    }

    pub fn setTitleOverride(self: *Self, title: ?[:0]const u8) void {
        const priv = self.private();
        if (priv.title_override) |v| glib.free(@ptrCast(@constCast(v)));
        priv.title_override = null;
        if (title) |v| priv.title_override = glib.ext.dupeZ(u8, v);
        self.as(gobject.Object).notifyByPspec(properties.@"title-override".impl.param_spec);
    }

    fn titleDialogSet(_: *TitleDialog, title_ptr: [*:0]const u8, self: *Self) callconv(.c) void {
        const title = std.mem.span(title_ptr);
        self.setTitleOverride(if (title.len == 0) null else title);
    }

    pub fn promptTitle(self: *Self) void {
        const priv = self.private();
        const dialog = TitleDialog.new(.tab, priv.title_override orelse priv.title);
        _ = TitleDialog.signals.set.connect(
            dialog,
            *Self,
            titleDialogSet,
            self,
            .{},
        );
        dialog.present(self.as(gtk.Widget));
    }

    pub fn getFocused(self: *Self) bool {
        const surface = self.getSurface() orelse return false;
        return surface.getFocused();
    }

    pub fn grabFocus(self: *Self) void {
        const surface = self.getSurface() orelse return;
        surface.grabFocus();
    }

    pub fn getNeedsConfirmQuit(self: *Self) bool {
        const surface = self.getSurface() orelse return false;
        const core = surface.core() orelse return false;
        return core.needsConfirmQuit();
    }

    fn getPageView(self: *Self) ?*adw.TabView {
        return ext.getAncestor(adw.TabView, self.as(gtk.Widget));
    }

    fn getPage(self: *Self) ?*adw.TabPage {
        const page_view = self.getPageView() orelse return null;
        return page_view.getPage(self.as(gtk.Widget));
    }

    fn actionPromptTabTitle(_: *gio.SimpleAction, _: ?*glib.Variant, self: *Self) callconv(.c) void {
        self.promptTitle();
    }

    fn actionRingBell(_: *gio.SimpleAction, _: ?*glib.Variant, self: *Self) callconv(.c) void {
        const page = self.getPage() orelse return;
        if (page.getSelected() != 0) return;
        page.setNeedsAttention(@intFromBool(true));
    }

    fn closureComputedTitle(
        _: *Self,
        terminal_: ?[*:0]const u8,
        surface_override_: ?[*:0]const u8,
        tab_override_: ?[*:0]const u8,
        unread_pending_: c_int,
        bell_ringing_: c_int,
        _: *gobject.ParamSpec,
    ) callconv(.c) ?[*:0]const u8 {
        const plain = std.mem.span(
            tab_override_ orelse
                surface_override_ orelse
                terminal_ orelse
                "Ghostty",
        );

        if (bell_ringing_ == 0 and unread_pending_ == 0) {
            return glib.ext.dupeZ(u8, plain);
        }

        var buf: std.Io.Writer.Allocating = .init(Application.default().allocator());
        defer buf.deinit();
        if (bell_ringing_ != 0) {
            buf.writer.writeAll("🔔 ") catch return glib.ext.dupeZ(u8, plain);
        } else {
            buf.writer.writeAll("• ") catch return glib.ext.dupeZ(u8, plain);
        }
        buf.writer.writeAll(plain) catch return glib.ext.dupeZ(u8, plain);
        return glib.ext.dupeZ(u8, buf.written());
    }

    fn dispose(self: *Self) callconv(.c) void {
        const priv = self.private();
        if (priv.action_group) |group| {
            self.as(gtk.Widget).insertActionGroup("tab", null);
            group.unref();
            priv.action_group = null;
        }
        gtk.Widget.disposeTemplate(self.as(gtk.Widget), getGObjectType());
        gobject.Object.virtual_methods.dispose.call(Class.parent, self.as(Parent));
    }

    fn finalize(self: *Self) callconv(.c) void {
        const priv = self.private();
        if (priv.title) |v| {
            glib.free(@ptrCast(@constCast(v)));
            priv.title = null;
        }
        if (priv.tooltip) |v| {
            glib.free(@ptrCast(@constCast(v)));
            priv.tooltip = null;
        }
        if (priv.title_override) |v| {
            glib.free(@ptrCast(@constCast(v)));
            priv.title_override = null;
        }

        gobject.Object.virtual_methods.finalize.call(Class.parent, self.as(Parent));
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
            gobject.ext.ensureType(Surface);
            gobject.ext.ensureType(SurfaceScrolledWindow);
            gtk.Widget.Class.setTemplateFromResource(
                class.as(gtk.Widget.Class),
                comptime gresource.blueprint(.{
                    .major = 1,
                    .minor = 5,
                    .name = "tab",
                }),
            );

            gobject.ext.registerProperties(class, &.{
                properties.surface.impl,
                properties.title.impl,
                properties.tooltip.impl,
                properties.@"title-override".impl,
            });

            class.bindTemplateChildPrivate("surface_scrolled_window", .{});
            class.bindTemplateCallback("computed_title", &closureComputedTitle);

            gobject.Object.virtual_methods.dispose.implement(class, &dispose);
            gobject.Object.virtual_methods.finalize.implement(class, &finalize);
        }

        pub const as = C.Class.as;
        pub const bindTemplateChildPrivate = C.Class.bindTemplateChildPrivate;
        pub const bindTemplateCallback = C.Class.bindTemplateCallback;
    };
};
