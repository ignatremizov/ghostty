const std = @import("std");
const adw = @import("adw");
const gio = @import("gio");
const glib = @import("glib");
const gobject = @import("gobject");
const gtk = @import("gtk");

const configpkg = @import("../../../config.zig");
const apprt = @import("../../../apprt.zig");
const CoreSurface = @import("../../../Surface.zig");
const ext = @import("../ext.zig");
const gresource = @import("../build/gresource.zig");
const Common = @import("../class.zig").Common;
const Config = @import("config.zig").Config;
const Application = @import("application.zig").Application;
const SplitTree = @import("split_tree.zig").SplitTree;
const SplitTabs = @import("split_tabs.zig").SplitTabs;
const Surface = @import("surface.zig").Surface;
const TitleDialog = @import("title_dialog.zig").TitleDialog;

const log = std.log.scoped(.gtk_ghostty_workspace_page);

pub const WorkspacePage = extern struct {
    const Self = @This();
    parent_instance: Parent,
    pub const Parent = gtk.Box;
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "GhosttyWorkspacePage",
        .instanceInit = &init,
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    pub const properties = struct {
        /// The active surface is the surface that should be receiving all
        /// surface-targeted actions. This is usually the focused surface,
        /// but may also not be focused if the user has selected a non-surface
        /// widget.
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
                        .{
                            .getter = Self.getActiveSurface,
                        },
                    ),
                },
            );
        };

        pub const config = struct {
            pub const name = "config";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                ?*Config,
                .{
                    .accessor = C.privateObjFieldAccessor("config"),
                },
            );
        };

        pub const @"split-tree" = struct {
            pub const name = "split-tree";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                ?*SplitTree,
                .{
                    .accessor = gobject.ext.typedAccessor(
                        Self,
                        ?*SplitTree,
                        .{
                            .getter = getSplitTree,
                        },
                    ),
                },
            );
        };

        pub const @"surface-tree" = struct {
            pub const name = "surface-tree";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                ?*SplitTabs.Tree,
                .{
                    .accessor = gobject.ext.typedAccessor(
                        Self,
                        ?*SplitTabs.Tree,
                        .{
                            .getter = getSurfaceTree,
                        },
                    ),
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

        pub const title = struct {
            pub const name = "title";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                ?[:0]const u8,
                .{
                    .default = null,
                    .accessor = gobject.ext.typedAccessor(
                        Self,
                        ?[:0]const u8,
                        .{
                            .getter = Self.getComputedTitle,
                            .getter_transfer = .none,
                            .setter = Self.setComputedTitle,
                            .setter_transfer = .full,
                        },
                    ),
                    .explicit_notify = true,
                },
            );
        };
        pub const @"surface-title" = struct {
            pub const name = "surface-title";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                ?[:0]const u8,
                .{
                    .default = null,
                    .accessor = gobject.ext.typedAccessor(
                        Self,
                        ?[:0]const u8,
                        .{
                            .getter = Self.getSurfaceTitle,
                            .getter_transfer = .none,
                            .setter = Self.setComputedSurfaceTitle,
                            .setter_transfer = .full,
                        },
                    ),
                    .explicit_notify = true,
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

        pub const @"sidebar-title" = struct {
            pub const name = "sidebar-title";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                ?[:0]const u8,
                .{
                    .default = null,
                    .accessor = gobject.ext.typedAccessor(
                        Self,
                        ?[:0]const u8,
                        .{
                            .getter = Self.getSidebarTitle,
                            .getter_transfer = .none,
                            .setter = Self.setComputedSidebarTitle,
                            .setter_transfer = .full,
                        },
                    ),
                    .explicit_notify = true,
                },
            );
        };

        pub const @"sidebar-subtitle" = struct {
            pub const name = "sidebar-subtitle";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                ?[:0]const u8,
                .{
                    .default = null,
                    .accessor = gobject.ext.typedAccessor(
                        Self,
                        ?[:0]const u8,
                        .{
                            .getter = Self.getSidebarSubtitle,
                            .getter_transfer = .none,
                            .setter = Self.setComputedSidebarSubtitle,
                            .setter_transfer = .full,
                        },
                    ),
                    .explicit_notify = true,
                },
            );
        };
    };

    pub const signals = struct {
        /// Emitted whenever the workspace page would like to be closed.
        pub const @"close-request" = struct {
            pub const name = "close-request";
            pub const connect = impl.connect;
            const impl = gobject.ext.defineSignal(
                name,
                Self,
                &.{},
                void,
            );
        };
    };

    const Private = struct {
        /// The configuration that this surface is using.
        config: ?*Config = null,
        action_group: ?*gio.SimpleActionGroup = null,

        /// The title of this workspace page. This is usually bound to the active surface.
        title: ?[:0]const u8 = null,

        /// Effective title copied from the active surface only while no
        /// workspace-level title override masks it.
        surface_title: ?[:0]const u8 = null,

        /// The manually overridden title from `promptWorkspaceTitle`.
        title_override: ?[:0]const u8 = null,

        /// Stable workspace name shown in the sidebar.
        sidebar_title: ?[:0]const u8 = null,

        /// Secondary workspace metadata shown in the sidebar.
        sidebar_subtitle: ?[:0]const u8 = null,

        /// The tooltip of this workspace page. This is usually bound to the active surface.
        tooltip: ?[:0]const u8 = null,

        // Template bindings
        split_tree: *SplitTree,
        title_source_bindings: ?*gobject.BindingGroup = null,

        pub var offset: c_int = 0;
    };

    const NewOptions = struct {
        command: ?configpkg.Command = null,
        working_directory: ?[:0]const u8 = null,
        title: ?[:0]const u8 = null,

        pub const none: @This() = .{};
    };

    /// Set the parent of this workspace page. This only affects the first surface
    /// ever created for a page. If a surface was already created this does
    /// nothing.
    pub fn setParent(self: *Self, parent: *CoreSurface) void {
        self.setParentWithContext(parent, .tab);
    }

    pub fn setParentWithContext(self: *Self, parent: *CoreSurface, context: apprt.surface.NewSurfaceContext) void {
        if (self.getActiveSurface()) |surface| {
            surface.setParent(parent, context);
        }
    }

    pub fn new(config: ?*Config, overrides: NewOptions) *Self {
        const page = gobject.ext.newInstance(WorkspacePage, .{});
        return page.initCommon(config, true, overrides);
    }

    pub fn newEmpty(config: ?*Config) *Self {
        const page = gobject.ext.newInstance(WorkspacePage, .{});
        return page.initCommon(config, false, .none);
    }

    fn initCommon(
        page: *Self,
        config: ?*Config,
        create_initial_surface: bool,
        overrides: NewOptions,
    ) *Self {
        const priv: *Private = page.private();

        if (config) |c| priv.config = c.ref();

        // If our configuration is null then we get the configuration
        // from the application.
        if (priv.config == null) {
            const app = Application.default();
            priv.config = app.getConfig();
        }

        page.as(gobject.Object).notifyByPspec(properties.config.impl.param_spec);

        if (create_initial_surface) {
            // Create our initial surface in the split tree.
            priv.split_tree.newSplit(.right, null, .{
                .command = overrides.command,
                .working_directory = overrides.working_directory,
                .title = overrides.title,
            }) catch |err| switch (err) {
                error.OutOfMemory => {
                    // TODO: We should make our "no surfaces" state more aesthetically
                    // pleasing and show something like an "Oops, something went wrong"
                    // message. For now, this is incredibly unlikely.
                    @panic("oom");
                },
            };
        }

        return page;
    }

    fn init(self: *Self, _: *Class) callconv(.c) void {
        gtk.Widget.initTemplate(self.as(gtk.Widget));

        // Init our actions
        self.initActionMap();

        const priv = self.private();
        priv.title_source_bindings = gobject.BindingGroup.new();
        priv.title_source_bindings.?.bind(
            "effective-title",
            self.as(gobject.Object),
            properties.@"surface-title".name,
            .{},
        );
        self.syncTitleSource();
    }

    fn initActionMap(self: *Self) void {
        const s_param_type = glib.ext.VariantType.newFor([:0]const u8);
        defer s_param_type.free();

        const actions = [_]ext.actions.Action(Self){
            .init("close", actionClose, s_param_type),
            .init("ring-bell", actionRingBell, null),
            .init("next-page", actionNextPage, null),
            .init("previous-page", actionPreviousPage, null),
            .init("prompt-tab-title", actionPromptWorkspaceTitle, null),
        };

        self.private().action_group = ext.actions.addAsGroup(Self, self, "workspace", &actions);
    }

    //---------------------------------------------------------------
    // Properties

    /// Overridden title. This will be generally be shown over the title
    /// unless this is unset (null).
    pub fn setTitleOverride(self: *Self, title: ?[:0]const u8) void {
        const priv = self.private();
        if (optionalStringEql(
            priv.title_override,
            if (title) |value| value else null,
        )) return;
        if (priv.title_override) |v| glib.free(@ptrCast(@constCast(v)));
        priv.title_override = null;
        if (title) |v| priv.title_override = glib.ext.dupeZ(u8, v);
        self.syncTitleSource();
        self.as(gobject.Object).notifyByPspec(properties.@"title-override".impl.param_spec);
    }
    fn titleDialogSet(
        _: *TitleDialog,
        title_ptr: [*:0]const u8,
        self: *Self,
    ) callconv(.c) void {
        const title = std.mem.span(title_ptr);
        self.setTitleOverride(if (title.len == 0) null else title);
    }
    pub fn promptWorkspaceTitle(self: *Self) void {
        const priv = self.private();
        const dialog = TitleDialog.new(
            .workspace,
            priv.title_override orelse priv.sidebar_title orelse priv.title,
        );
        _ = TitleDialog.signals.set.connect(
            dialog,
            *Self,
            titleDialogSet,
            self,
            .{},
        );

        dialog.present(self.as(gtk.Widget));
    }

    /// Get the currently active surface. See the "active-surface" property.
    /// This does not ref the value.
    pub fn getActiveSurface(self: *Self) ?*Surface {
        return self.getSplitTree().getActiveSurface();
    }

    pub fn getTitleOverride(self: *Self) ?[:0]const u8 {
        return self.private().title_override;
    }

    fn getComputedTitle(self: *Self) ?[:0]const u8 {
        return self.private().title;
    }

    fn getSurfaceTitle(self: *Self) ?[:0]const u8 {
        return self.private().surface_title;
    }

    fn setComputedTitle(self: *Self, title: ?[:0]const u8) void {
        self.replaceComputedString(
            &self.private().title,
            title,
            properties.title.impl.param_spec,
        );
    }

    fn setComputedSurfaceTitle(self: *Self, title: ?[:0]const u8) void {
        self.replaceComputedString(
            &self.private().surface_title,
            title,
            properties.@"surface-title".impl.param_spec,
        );
    }

    fn syncTitleSource(self: *Self) void {
        const priv = self.private();
        const source = if (priv.title_override == null)
            if (self.getActiveSurface()) |surface| surface.as(gobject.Object) else null
        else
            null;
        const bindings = priv.title_source_bindings orelse return;
        bindings.setSource(source);
        if (source == null) self.setComputedSurfaceTitle(null);
    }

    pub fn getSidebarTitle(self: *Self) ?[:0]const u8 {
        return self.private().sidebar_title;
    }

    pub fn setSidebarTitle(self: *Self, title: ?[:0]const u8) void {
        self.setComputedSidebarTitle(
            if (title) |value| glib.ext.dupeZ(u8, value) else null,
        );
    }

    pub fn getSidebarSubtitle(self: *Self) ?[:0]const u8 {
        return self.private().sidebar_subtitle;
    }

    fn setComputedSidebarTitle(self: *Self, title: ?[:0]const u8) void {
        self.replaceComputedString(
            &self.private().sidebar_title,
            title,
            properties.@"sidebar-title".impl.param_spec,
        );
    }

    fn setComputedSidebarSubtitle(self: *Self, title: ?[:0]const u8) void {
        self.replaceComputedString(
            &self.private().sidebar_subtitle,
            title,
            properties.@"sidebar-subtitle".impl.param_spec,
        );
    }

    fn replaceComputedString(
        self: *Self,
        field: *?[:0]const u8,
        value: ?[:0]const u8,
        param_spec: *gobject.ParamSpec,
    ) void {
        if (optionalStringEql(field.*, value)) {
            if (value) |unchanged| glib.free(@ptrCast(@constCast(unchanged)));
            return;
        }
        if (field.*) |current| glib.free(@ptrCast(@constCast(current)));
        field.* = value;
        self.as(gobject.Object).notifyByPspec(param_spec);
    }

    fn optionalStringEql(
        current: ?[:0]const u8,
        next: ?[:0]const u8,
    ) bool {
        if (current) |current_value| {
            const next_value = next orelse return false;
            return std.mem.eql(u8, current_value, next_value);
        }
        return next == null;
    }

    pub fn getTooltip(self: *Self) ?[:0]const u8 {
        return self.private().tooltip;
    }

    /// Get the surface tree of this workspace page.
    pub fn getSurfaceTree(self: *Self) ?*SplitTabs.Tree {
        const priv = self.private();
        return priv.split_tree.getTree();
    }

    /// Get the split tree widget hosted in this workspace page.
    pub fn getSplitTree(self: *Self) *SplitTree {
        const priv = self.private();
        return priv.split_tree;
    }

    /// Returns true if this workspace page needs confirmation before quitting based
    /// on the various Ghostty configurations.
    pub fn getNeedsConfirmQuit(self: *Self) bool {
        const tree = self.getSplitTree();
        return tree.getNeedsConfirmQuit();
    }

    pub fn newTab(self: *Self, parent_: ?*Surface) void {
        self.getSplitTree().newTab(parent_, .none) catch |err| switch (err) {
            error.OutOfMemory => @panic("oom"),
        };
    }

    /// Get the top-level page view holding this workspace page, if any.
    fn getPageView(self: *Self) ?*adw.TabView {
        return ext.getAncestor(
            adw.TabView,
            self.as(gtk.Widget),
        );
    }

    /// Get the page object holding this workspace page, if any.
    fn getPage(self: *Self) ?*adw.TabPage {
        const page_view = self.getPageView() orelse return null;
        return page_view.getPage(self.as(gtk.Widget));
    }

    //---------------------------------------------------------------
    // Virtual methods

    fn dispose(self: *Self) callconv(.c) void {
        const priv = self.private();
        if (priv.title_source_bindings) |bindings| {
            bindings.setSource(null);
            bindings.unref();
            priv.title_source_bindings = null;
        }
        if (priv.config) |v| {
            v.unref();
            priv.config = null;
        }
        if (priv.action_group) |group| {
            self.as(gtk.Widget).insertActionGroup("workspace", null);
            group.unref();
            priv.action_group = null;
        }

        gtk.Widget.disposeTemplate(
            self.as(gtk.Widget),
            getGObjectType(),
        );

        gobject.Object.virtual_methods.dispose.call(
            Class.parent,
            self.as(Parent),
        );
    }

    fn finalize(self: *Self) callconv(.c) void {
        const priv = self.private();
        if (priv.tooltip) |v| {
            glib.free(@ptrCast(@constCast(v)));
            priv.tooltip = null;
        }
        if (priv.title) |v| {
            glib.free(@ptrCast(@constCast(v)));
            priv.title = null;
        }
        if (priv.surface_title) |v| {
            glib.free(@ptrCast(@constCast(v)));
            priv.surface_title = null;
        }
        if (priv.title_override) |v| {
            glib.free(@ptrCast(@constCast(v)));
            priv.title_override = null;
        }
        if (priv.sidebar_title) |v| {
            glib.free(@ptrCast(@constCast(v)));
            priv.sidebar_title = null;
        }
        if (priv.sidebar_subtitle) |v| {
            glib.free(@ptrCast(@constCast(v)));
            priv.sidebar_subtitle = null;
        }

        gobject.Object.virtual_methods.finalize.call(
            Class.parent,
            self.as(Parent),
        );
    }
    //---------------------------------------------------------------
    // Signal handlers

    fn propSplitTree(
        _: *SplitTree,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        self.as(gobject.Object).notifyByPspec(properties.@"surface-tree".impl.param_spec);

        // If our tree is empty we close the workspace page.
        const tree: *const SplitTabs.Tree = self.getSurfaceTree() orelse &.empty;
        if (tree.isEmpty()) {
            signals.@"close-request".impl.emit(
                self,
                null,
                .{},
                null,
            );
            return;
        }
    }

    fn propActiveSurface(
        _: *SplitTree,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        self.syncTitleSource();
        self.as(gobject.Object).notifyByPspec(properties.@"active-surface".impl.param_spec);
    }

    fn actionClose(
        _: *gio.SimpleAction,
        param_: ?*glib.Variant,
        self: *Self,
    ) callconv(.c) void {
        const param = param_ orelse {
            log.warn("workspace.close called without a parameter", .{});
            return;
        };

        var str: ?[*:0]const u8 = null;
        param.get("&s", &str);

        const page_view = self.getPageView() orelse return;
        const page = page_view.getPage(self.as(gtk.Widget));

        const mode = std.meta.stringToEnum(
            apprt.action.CloseTabMode,
            std.mem.span(
                str orelse {
                    log.warn("invalid mode provided to workspace.close", .{});
                    return;
                },
            ),
        ) orelse {
            // Need to be defensive here since actions can be triggered externally.
            log.warn("invalid mode provided to workspace.close: {s}", .{str.?});
            return;
        };

        // Delegate to our parent to handle this, since this will emit
        // a close-page signal that the parent can intercept.
        switch (mode) {
            .this => page_view.closePage(page),
            .other => page_view.closeOtherPages(page),
            .right => page_view.closePagesAfter(page),
        }
    }

    fn actionPromptWorkspaceTitle(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Self,
    ) callconv(.c) void {
        self.promptWorkspaceTitle();
    }

    fn actionRingBell(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Self,
    ) callconv(.c) void {
        // Future note: I actually don't like this logic living here at all.
        // I think a better approach will be for the ring bell action to
        // specify its sending surface and then do all this in the window.

        // If the page is selected already we don't mark it as needing
        // attention. We only want to mark unfocused pages. This will then
        // clear when the page is selected.
        const page = self.getPage() orelse return;
        if (page.getSelected() != 0) return;
        page.setNeedsAttention(@intFromBool(true));
    }

    /// Select the next workspace page.
    fn actionNextPage(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Self,
    ) callconv(.c) void {
        const page_view = self.getPageView() orelse return;
        _ = page_view.selectNextPage();
    }

    /// Select the previous workspace page.
    fn actionPreviousPage(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Self,
    ) callconv(.c) void {
        const page_view = self.getPageView() orelse return;
        _ = page_view.selectPreviousPage();
    }

    fn closureComputedTitle(
        _: *Self,
        config_: ?*Config,
        surface_title_: ?[*:0]const u8,
        workspace_override_: ?[*:0]const u8,
        zoomed_: c_int,
        bell_ringing_: c_int,
        _: *gobject.ParamSpec,
    ) callconv(.c) ?[*:0]const u8 {
        const zoomed = zoomed_ != 0;
        const bell_ringing = bell_ringing_ != 0;

        // Our plain title is the manually workspace-page overridden title if it exists,
        // otherwise the overridden title if it exists, otherwise
        // the terminal title if it exists, otherwise a default string.
        const plain = plain: {
            const default = "Ghostty";
            const config_title: ?[*:0]const u8 = title: {
                const config = config_ orelse break :title null;
                break :title config.get().title orelse null;
            };

            const plain = workspace_override_ orelse
                surface_title_ orelse
                config_title orelse
                break :plain default;
            break :plain std.mem.span(plain);
        };

        if (!zoomed and !bell_ringing) {
            return glib.ext.dupeZ(u8, plain);
        }

        // We don't need a config in every case, but if we don't have a config
        // let's just assume something went terribly wrong and use our
        // default title. Its easier then guarding on the config existing
        // in every case for something so unlikely.
        const config = if (config_) |v| v.get() else {
            log.warn("config unavailable for computed title, likely bug", .{});
            return glib.ext.dupeZ(u8, plain);
        };

        // Use an allocator to build up our string as we write it.
        var buf: std.Io.Writer.Allocating = .init(Application.default().allocator());
        defer buf.deinit();

        // If our bell is ringing, then we prefix the bell icon to the title.
        if (bell_ringing and config.@"bell-features".title) {
            buf.writer.writeAll("🔔 ") catch {};
        }

        // If we're zoomed, prefix with the magnifying glass emoji.
        if (zoomed) {
            buf.writer.writeAll("🔍 ") catch {};
        }

        buf.writer.writeAll(plain) catch return glib.ext.dupeZ(u8, plain);
        return glib.ext.dupeZ(u8, buf.written());
    }

    fn closureComputedSidebarTitle(
        _: *Self,
        derived_: ?[*:0]const u8,
        workspace_override_: ?[*:0]const u8,
        _: *gobject.ParamSpec,
    ) callconv(.c) ?[*:0]const u8 {
        if (workspace_override_) |workspace_override| {
            return glib.ext.dupeZ(u8, std.mem.span(workspace_override));
        }

        if (derived_) |derived| {
            return glib.ext.dupeZ(u8, std.mem.span(derived));
        }

        return glib.ext.dupeZ(u8, "Workspace");
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
            gobject.ext.ensureType(SplitTree);
            gobject.ext.ensureType(Surface);
            gtk.Widget.Class.setTemplateFromResource(
                class.as(gtk.Widget.Class),
                comptime gresource.blueprint(.{
                    .major = 1,
                    .minor = 5,
                    .name = "workspace-page",
                }),
            );

            // Properties
            gobject.ext.registerProperties(class, &.{
                properties.@"active-surface".impl,
                properties.config.impl,
                properties.@"split-tree".impl,
                properties.@"surface-tree".impl,
                properties.title.impl,
                properties.@"surface-title".impl,
                properties.@"title-override".impl,
                properties.tooltip.impl,
                properties.@"sidebar-title".impl,
                properties.@"sidebar-subtitle".impl,
            });

            // Bindings
            class.bindTemplateChildPrivate("split_tree", .{});

            // Template Callbacks
            class.bindTemplateCallback("computed_title", &closureComputedTitle);
            class.bindTemplateCallback("computed_sidebar_title", &closureComputedSidebarTitle);
            class.bindTemplateCallback("notify_active_surface", &propActiveSurface);
            class.bindTemplateCallback("notify_tree", &propSplitTree);

            // Signals
            signals.@"close-request".impl.register(.{});

            // Virtual methods
            gobject.Object.virtual_methods.dispose.implement(class, &dispose);
            gobject.Object.virtual_methods.finalize.implement(class, &finalize);
        }

        pub const as = C.Class.as;
        pub const bindTemplateChildPrivate = C.Class.bindTemplateChildPrivate;
        pub const bindTemplateCallback = C.Class.bindTemplateCallback;
    };
};
