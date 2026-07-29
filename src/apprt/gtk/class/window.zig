const std = @import("std");
const build_config = @import("../../../build_config.zig");
const assert = @import("../../../quirks.zig").inlineAssert;
const adw = @import("adw");
const gdk = @import("gdk");
const gio = @import("gio");
const glib = @import("glib");
const gobject = @import("gobject");
const gtk = @import("gtk");

const i18n = @import("../../../os/main.zig").i18n;
const internal_os = @import("../../../os/main.zig");
const apprt = @import("../../../apprt.zig");
const configpkg = @import("../../../config.zig");
const TitlebarStyle = configpkg.Config.GtkTitlebarStyle;
const input = @import("../../../input.zig");
const CoreSurface = @import("../../../Surface.zig");
const ext = @import("../ext.zig");
const gtk_version = @import("../gtk_version.zig");
const adw_version = @import("../adw_version.zig");
const gresource = @import("../build/gresource.zig");
const winprotopkg = @import("../winproto.zig");
const Common = @import("../class.zig").Common;
const Config = @import("config.zig").Config;
const Application = @import("application.zig").Application;
const CloseConfirmationDialog = @import("close_confirmation_dialog.zig").CloseConfirmationDialog;
const SplitTree = @import("split_tree.zig").SplitTree;
const SplitTabs = @import("split_tabs.zig").SplitTabs;
const Surface = @import("surface.zig").Surface;
const Tab = @import("tab.zig").Tab;
const WorkspacePage = @import("workspace_page.zig").WorkspacePage;
const WorkspaceSidebar = @import("workspace_sidebar.zig").WorkspaceSidebar;
const DebugWarning = @import("debug_warning.zig").DebugWarning;
const CommandPalette = @import("command_palette.zig").CommandPalette;
const WeakRef = @import("../weak_ref.zig").WeakRef;
const workspace_ids = @import("../workspace_ids.zig");
const workspace_attention = @import("../workspace_attention.zig");
const workspace_model = @import("../workspace_model.zig");
const workspace_registry = @import("../workspace_registry.zig");
const workspace_restore = @import("../workspace_restore.zig");
const workspace_snapshot = @import("../workspace_snapshot.zig");
const workspace_storage = @import("../workspace_storage.zig");
const termio = @import("../../../termio.zig");

const log = std.log.scoped(.gtk_ghostty_window);
const workspace_periodic_autosave_ms = 10 * 60 * 1000;
const workspace_autosave_scrollback_session_bytes = 16 * 1024 * 1024;
const workspace_autosave_scrollback_total_bytes = 32 * 1024 * 1024;

const AutosaveScrollbackBudget = struct {
    remaining: usize = workspace_autosave_scrollback_total_bytes,
    per_session: usize,

    fn init(session_count: usize) AutosaveScrollbackBudget {
        const fair_share = if (session_count == 0)
            workspace_autosave_scrollback_total_bytes
        else
            @max(
                @as(usize, 1),
                workspace_autosave_scrollback_total_bytes / session_count,
            );
        return .{
            .per_session = @min(
                workspace_autosave_scrollback_session_bytes,
                fair_share,
            ),
        };
    }
};

fn workspacePageSurfaceCount(workspace_page: *WorkspacePage) usize {
    const tree = workspace_page.getSurfaceTree() orelse return 0;
    var result: usize = 0;
    var it = tree.iterator();
    while (it.next()) |entry| {
        result += @intCast(entry.view.getSurfaceCount());
    }
    return result;
}

pub const Window = extern struct {
    const Self = @This();
    parent_instance: Parent,
    pub const Parent = adw.ApplicationWindow;
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "GhosttyWindow",
        .instanceInit = &init,
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    pub const properties = struct {
        /// The active surface is the focus that should be receiving all
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

        pub const debug = struct {
            pub const name = "debug";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                bool,
                .{
                    .default = build_config.is_debug,
                    .accessor = gobject.ext.typedAccessor(Self, bool, .{
                        .getter = struct {
                            pub fn getter(_: *Self) bool {
                                return build_config.is_debug;
                            }
                        }.getter,
                    }),
                },
            );
        };

        pub const @"titlebar-style" = struct {
            pub const name = "titlebar-style";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                TitlebarStyle,
                .{
                    .default = .native,
                    .accessor = gobject.ext.typedAccessor(
                        Self,
                        TitlebarStyle,
                        .{
                            .getter = Self.getTitlebarStyle,
                        },
                    ),
                },
            );
        };

        pub const @"headerbar-visible" = struct {
            pub const name = "headerbar-visible";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                bool,
                .{
                    .default = true,
                    .accessor = gobject.ext.typedAccessor(Self, bool, .{
                        .getter = Self.getHeaderbarVisible,
                    }),
                },
            );
        };

        pub const @"quick-terminal" = struct {
            pub const name = "quick-terminal";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                bool,
                .{
                    .default = true,
                    .accessor = gobject.ext.privateFieldAccessor(
                        Self,
                        Private,
                        &Private.offset,
                        "quick_terminal",
                    ),
                },
            );
        };

        pub const @"tabs-autohide" = struct {
            pub const name = "tabs-autohide";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                bool,
                .{
                    .default = true,
                    .accessor = gobject.ext.typedAccessor(Self, bool, .{
                        .getter = Self.getTabsAutohide,
                    }),
                },
            );
        };

        pub const @"tabs-wide" = struct {
            pub const name = "tabs-wide";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                bool,
                .{
                    .default = true,
                    .accessor = gobject.ext.typedAccessor(Self, bool, .{
                        .getter = Self.getTabsWide,
                    }),
                },
            );
        };

        pub const @"tabs-visible" = struct {
            pub const name = "tabs-visible";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                bool,
                .{
                    .default = true,
                    .accessor = gobject.ext.typedAccessor(Self, bool, .{
                        .getter = Self.getTabsVisible,
                    }),
                },
            );
        };

        pub const @"toolbar-style" = struct {
            pub const name = "toolbar-style";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                adw.ToolbarStyle,
                .{
                    .default = .raised,
                    .accessor = gobject.ext.typedAccessor(
                        Self,
                        adw.ToolbarStyle,
                        .{
                            .getter = Self.getToolbarStyle,
                        },
                    ),
                },
            );
        };
    };

    const Private = struct {
        /// Whether this window is a quick terminal. If it is then it
        /// behaves slightly differently under certain scenarios.
        quick_terminal: bool = false,

        /// Timeout source to react to this window becoming (in)active.
        handle_active_state_source: ?c_uint = null,

        /// The window decoration override. If this is not set then we'll
        /// inherit whatever the config has. This allows overriding the
        /// config on a per-window basis.
        window_decoration: ?configpkg.WindowDecoration = null,

        /// Binding group for our active workspace page.
        workspace_page_bindings: *gobject.BindingGroup,

        /// The configuration that this surface is using.
        config: ?*Config = null,

        /// State and logic for windowing protocol for a window.
        winproto: winprotopkg.Window,

        /// Kind of hacky to have this but this lets us know if we've
        /// initialized any single surface yet. We need this because we
        /// gate default size on this so that we don't resize the window
        /// after surfaces already exist.
        ///
        /// I think long term we can probably get rid of this by implementing
        /// a property or method that gets us all the surfaces in all the
        /// tabs and checking if we have zero or one that isn't initialized.
        ///
        /// For now, this logic is more similar to our legacy GTK side.
        surface_init: bool = false,

        /// See tabOverviewOpen for why we have this.
        tab_overview_focus_timer: ?c_uint = null,

        /// A weak reference to a command palette.
        command_palette: WeakRef(CommandPalette) = .empty,

        /// Workspace page that the context menu was opened for.
        /// setup by `setup-menu`.
        context_menu_page: ?*adw.TabPage = null,
        pending_surface_focus_source: ?c_uint = null,
        pending_workspace_autosave_source: ?c_uint = null,
        pending_workspace_autosave_page: ?*WorkspacePage = null,
        periodic_workspace_autosave_source: ?c_uint = null,
        shutdown_autosave_complete: bool = false,
        disposing_runtime: bool = false,
        runtime_window_id: ?workspace_ids.WindowId = null,
        runtime_registry: workspace_registry.Registry,
        session_identity_index: workspace_registry.SessionIdentityIndex,
        scrollback_saved_states: std.AutoHashMap(workspace_ids.SessionId, SavedScrollbackState),
        workspace_ids_by_page: std.AutoHashMap(usize, workspace_ids.WorkspaceId),
        split_ids_by_leaf: std.AutoHashMap(usize, workspace_ids.SplitId),
        tab_ids_by_widget: std.AutoHashMap(usize, workspace_ids.TabId),
        surface_ids_by_widget: std.AutoHashMap(usize, workspace_ids.SurfaceId),

        // Template bindings
        tab_overview: *adw.TabOverview,
        tab_bar: *adw.TabBar,
        tab_view: *adw.TabView,
        toolbar: *adw.ToolbarView,
        toast_overlay: *adw.ToastOverlay,
        workspace_split_view: *gtk.Paned,
        workspace_sidebar: *WorkspaceSidebar,
        workspace_sidebar_position: c_int = 280,

        pub var offset: c_int = 0;
    };

    const WorkspacePageIdleAction = enum {
        prompt_title,
        save,
        reveal_snapshot,
        open_snapshot,
        delete_snapshot,
        close,
    };

    pub fn new(
        app: *Application,
        overrides: struct {
            title: ?[:0]const u8 = null,

            pub const none: @This() = .{};
        },
    ) *Self {
        const win = gobject.ext.newInstance(Self, .{
            .application = app,
        });

        if (overrides.title) |title| {
            // If the overrides have a title set, we set that immediately
            // so that any applications inspecting the window states see an
            // immediate title set when the window appears, rather than waiting
            // possibly a few event loop ticks for it to sync from the surface.
            win.as(gtk.Window).setTitle(title);
        }

        return win;
    }

    fn init(self: *Self, _: *Class) callconv(.c) void {
        gtk.Widget.initTemplate(self.as(gtk.Widget));

        // If our configuration is null then we get the configuration
        // from the application.
        const priv = self.private();
        const app = Application.default();

        const config = config: {
            if (priv.config) |config| break :config config.get();
            const config = app.getConfig();
            priv.config = config;
            break :config config.get();
        };

        // We initialize our windowing protocol to none because we can't
        // actually initialize this until we get realized.
        priv.winproto = .none;

        // Add our dev CSS class if we're in debug mode.
        if (comptime build_config.is_debug) {
            self.as(gtk.Widget).addCssClass("devel");
        }

        // Setup our workspace-page binding group. This ensures certain
        // properties are only synced from the currently active page.
        priv.workspace_page_bindings = gobject.BindingGroup.new();
        priv.workspace_page_bindings.bind("title", self.as(gobject.Object), "title", .{});
        priv.runtime_registry = workspace_registry.Registry.init(app.allocator());
        priv.session_identity_index = workspace_registry.SessionIdentityIndex.init(app.allocator());
        priv.scrollback_saved_states = std.AutoHashMap(workspace_ids.SessionId, SavedScrollbackState).init(app.allocator());
        priv.workspace_ids_by_page = std.AutoHashMap(usize, workspace_ids.WorkspaceId).init(app.allocator());
        priv.split_ids_by_leaf = std.AutoHashMap(usize, workspace_ids.SplitId).init(app.allocator());
        priv.tab_ids_by_widget = std.AutoHashMap(usize, workspace_ids.TabId).init(app.allocator());
        priv.surface_ids_by_widget = std.AutoHashMap(usize, workspace_ids.SurfaceId).init(app.allocator());
        priv.periodic_workspace_autosave_source = glib.timeoutAdd(
            workspace_periodic_autosave_ms,
            periodicWorkspaceAutosave,
            self,
        );

        // Set our window icon. We can't set this in the blueprint file
        // because its dependent on the build config.
        self.as(gtk.Window).setIconName(build_config.bundle_id);

        // Initialize our actions
        self.initActionMap();

        priv.workspace_sidebar.bindModel(priv.tab_view.getPages().as(gio.ListModel));
        _ = WorkspaceSidebar.signals.@"workspace-selected".connect(
            priv.workspace_sidebar,
            *Self,
            workspaceSidebarWorkspaceSelected,
            self,
            .{},
        );
        _ = WorkspaceSidebar.signals.@"new-workspace".connect(
            priv.workspace_sidebar,
            *Self,
            workspaceSidebarNewWorkspace,
            self,
            .{},
        );
        _ = WorkspaceSidebar.signals.@"prompt-workspace-title".connect(
            priv.workspace_sidebar,
            *Self,
            workspaceSidebarPromptWorkspaceTitle,
            self,
            .{},
        );
        _ = WorkspaceSidebar.signals.@"save-workspace".connect(
            priv.workspace_sidebar,
            *Self,
            workspaceSidebarSaveWorkspace,
            self,
            .{},
        );
        _ = WorkspaceSidebar.signals.@"reveal-workspace-snapshot".connect(
            priv.workspace_sidebar,
            *Self,
            workspaceSidebarRevealWorkspaceSnapshot,
            self,
            .{},
        );
        _ = WorkspaceSidebar.signals.@"open-workspace-snapshot".connect(
            priv.workspace_sidebar,
            *Self,
            workspaceSidebarOpenWorkspaceSnapshot,
            self,
            .{},
        );
        _ = WorkspaceSidebar.signals.@"delete-workspace".connect(
            priv.workspace_sidebar,
            *Self,
            workspaceSidebarDeleteWorkspace,
            self,
            .{},
        );
        _ = WorkspaceSidebar.signals.@"close-workspace".connect(
            priv.workspace_sidebar,
            *Self,
            workspaceSidebarCloseWorkspace,
            self,
            .{},
        );
        _ = WorkspaceSidebar.signals.@"restore-workspace".connect(
            priv.workspace_sidebar,
            *Self,
            workspaceSidebarRestoreWorkspace,
            self,
            .{},
        );
        self.syncWorkspaceSidebarSelection();
        self.refreshWorkspaceRegistry() catch |err| {
            log.warn("failed to build initial workspace registry error={}", .{err});
        };

        // Start states based on config.
        if (config.maximize) self.as(gtk.Window).maximize();
        if (config.fullscreen != .false) self.as(gtk.Window).fullscreen();

        // If we have an explicit title set, we set that immediately
        // so that any applications inspecting the window states see
        // an immediate title set when the window appears, rather than
        // waiting possibly a few event loop ticks for it to sync from
        // the surface.
        if (config.title) |title| {
            self.as(gtk.Window).setTitle(title);
        }

        // We always sync our appearance at the end because loading our
        // config and such can affect our bindings which are setup initially
        // in initTemplate.
        self.syncAppearance();

        // We need to do this so that the title initializes properly,
        // I think because its a dynamic getter.
        self.as(gobject.Object).notifyByPspec(properties.@"active-surface".impl.param_spec);
    }

    /// Setup our action map.
    fn initActionMap(self: *Self) void {
        const s_variant_type = glib.ext.VariantType.newFor([:0]const u8);
        defer s_variant_type.free();

        const actions = [_]ext.actions.Action(Self){
            .init("about", actionAbout, null),
            .init("close", actionClose, null),
            .init("close-tab", actionCloseTab, s_variant_type),
            .init("new-tab", actionNewTab, null),
            .init("new-window", actionNewWindow, null),
            .init("prompt-workspace-title", actionPromptWorkspaceTitle, null),
            .init("prompt-surface-title", actionPromptSurfaceTitle, null),
            .init("prompt-tab-title", actionPromptTabTitle, null),
            .init("prompt-context-workspace-title", actionPromptContextWorkspaceTitle, null),
            .init("save-context-workspace", actionSaveContextWorkspace, null),
            .init("open-context-workspace-snapshot", actionOpenContextWorkspaceSnapshot, null),
            .init("reveal-context-workspace-snapshot", actionRevealContextWorkspaceSnapshot, null),
            .init("close-context-workspace", actionCloseContextWorkspace, null),
            .init("ring-bell", actionRingBell, null),
            .init("split-right", actionSplitRight, null),
            .init("split-left", actionSplitLeft, null),
            .init("split-up", actionSplitUp, null),
            .init("split-down", actionSplitDown, null),
            .init("copy", actionCopy, null),
            .init("paste", actionPaste, null),
            .init("reset", actionReset, null),
            .init("clear", actionClear, null),
            // TODO: accept the surface that toggled the command palette
            .init("toggle-command-palette", actionToggleCommandPalette, null),
            .init("toggle-inspector", actionToggleInspector, null),
        };

        ext.actions.add(Self, self, &actions);
    }

    /// Winproto backend for this window.
    pub fn winproto(self: *Self) *winprotopkg.Window {
        return &self.private().winproto;
    }

    /// Create a new workspace page with the given parent. The page will be
    /// inserted at the position dictated by the `window-new-tab-position`
    /// config. The new page will be selected.
    pub fn newWorkspace(self: *Self, parent_: ?*CoreSurface) void {
        _ = self.newWorkspacePage(parent_, .tab, .none);
    }

    pub fn newTab(self: *Self, parent_: ?*CoreSurface) void {
        const parent_surface = if (parent_) |parent| parent.rt_surface.surface else self.getActiveSurface();
        const workspace_page = if (parent_surface) |surface|
            ext.getAncestor(WorkspacePage, surface.as(gtk.Widget)) orelse self.getSelectedWorkspacePage() orelse return
        else
            self.getSelectedWorkspacePage() orelse return;

        workspace_page.newTab(parent_surface);
    }

    pub fn newWorkspaceForWindow(
        self: *Self,
        parent_: ?*CoreSurface,
        overrides: struct {
            command: ?configpkg.Command = null,
            working_directory: ?[:0]const u8 = null,
            title: ?[:0]const u8 = null,

            pub const none: @This() = .{};
        },
    ) void {
        _ = self.newWorkspacePage(
            parent_,
            .window,
            .{
                .command = overrides.command,
                .working_directory = overrides.working_directory,
                .title = overrides.title,
            },
        );
    }

    pub fn newTabForWindow(
        self: *Self,
        parent_: ?*CoreSurface,
        overrides: struct {
            command: ?configpkg.Command = null,
            working_directory: ?[:0]const u8 = null,
            title: ?[:0]const u8 = null,

            pub const none: @This() = .{};
        },
    ) void {
        self.newWorkspaceForWindow(parent_, .{
            .command = overrides.command,
            .working_directory = overrides.working_directory,
            .title = overrides.title,
        });
    }

    fn newWorkspacePage(
        self: *Self,
        parent_: ?*CoreSurface,
        context: apprt.surface.NewSurfaceContext,
        overrides: struct {
            command: ?configpkg.Command = null,
            working_directory: ?[:0]const u8 = null,
            title: ?[:0]const u8 = null,
            initial_surface: bool = true,
            position_override: ?c_int = null,
            select_page: bool = true,

            pub const none: @This() = .{};
        },
    ) *adw.TabPage {
        const priv: *Private = self.private();
        const tab_view = priv.tab_view;

        // Create our new workspace page object.
        const workspace_page = if (overrides.initial_surface)
            WorkspacePage.new(
                priv.config,
                .{
                    .command = overrides.command,
                    .working_directory = overrides.working_directory,
                    .title = overrides.title,
                },
            )
        else
            WorkspacePage.newEmpty(priv.config);

        if (parent_) |p| {
            // For a new window's first tab, inherit the parent's initial size hints.
            if (context == .window) {
                surfaceInit(p.rt_surface.gobj(), self);
            }
            workspace_page.setParentWithContext(p, context);
        }

        // Get the position that we should insert the new tab at.
        const config = if (priv.config) |v| v.get() else {
            // If we don't have a config we just append it at the end.
            // This should never happen.
            return tab_view.append(workspace_page.as(gtk.Widget));
        };
        const position = overrides.position_override orelse switch (config.@"window-new-tab-position") {
            .current => current: {
                const selected = tab_view.getSelectedPage() orelse
                    break :current tab_view.getNPages();
                const current = tab_view.getPagePosition(selected);
                break :current current + 1;
            },

            .end => tab_view.getNPages(),
        };

        // Add the page and select it
        const page = tab_view.insert(workspace_page.as(gtk.Widget), position);
        if (overrides.select_page) tab_view.setSelectedPage(page);

        // Create some property bindings
        _ = workspace_page.as(gobject.Object).bindProperty(
            "title",
            page.as(gobject.Object),
            "title",
            .{ .sync_create = true },
        );
        _ = workspace_page.as(gobject.Object).bindProperty(
            "tooltip",
            page.as(gobject.Object),
            "tooltip",
            .{ .sync_create = true },
        );

        // Bind signals
        const split_tree = workspace_page.getSplitTree();
        _ = SplitTree.signals.changed.connect(
            split_tree,
            *Self,
            workspacePageSplitTreeChanged,
            self,
            .{},
        );
        _ = SplitTree.signals.@"surface-added".connect(
            split_tree,
            *Self,
            workspacePageSurfaceAdded,
            self,
            .{},
        );
        _ = SplitTree.signals.@"surface-removed".connect(
            split_tree,
            *Self,
            workspacePageSurfaceRemoved,
            self,
            .{},
        );

        // Run an initial notification for the surface tree so we can setup
        // initial state.
        workspacePageSplitTreeChanged(
            split_tree,
            null,
            split_tree.getTree(),
            self,
        );

        return page;
    }

    pub const SelectTab = union(enum) {
        previous,
        next,
        last,
        n: usize,
    };

    /// Select the tab as requested. Returns true if the tab selection
    /// changed.
    pub fn selectTab(self: *Self, n: SelectTab) bool {
        const surface = self.getActiveSurface() orelse return false;
        const split_tabs = ext.getAncestor(
            SplitTabs,
            surface.as(gtk.Widget),
        ) orelse return false;
        return split_tabs.selectTab(switch (n) {
            .previous => .previous,
            .next => .next,
            .last => .last,
            .n => |idx| .{ .n = idx },
        });
    }

    /// Move the tab containing the given surface by the given amount.
    /// Returns if this affected any tab positioning.
    pub fn moveTab(
        _: *Self,
        surface: *Surface,
        amount: isize,
    ) bool {
        const split_tabs = ext.getAncestor(
            SplitTabs,
            surface.as(gtk.Widget),
        ) orelse return false;
        return split_tabs.moveSurface(surface, amount);
    }

    fn newEmptyWorkspacePage(
        self: *Self,
        position: c_int,
        select_page: bool,
    ) *adw.TabPage {
        return self.newWorkspacePage(null, .tab, .{
            .initial_surface = false,
            .position_override = position,
            .select_page = select_page,
        });
    }

    /// Move the given surface into another workspace page, merging it as a
    /// split in the destination page.
    pub fn moveSurfaceToWorkspace(
        self: *Self,
        surface: *Surface,
        target: SelectTab,
    ) bool {
        const priv = self.private();
        const tab_view = priv.tab_view;

        const source_workspace_page = ext.getAncestor(
            WorkspacePage,
            surface.as(gtk.Widget),
        ) orelse return false;
        const source_page = tab_view.getPage(source_workspace_page.as(gtk.Widget));
        const total = tab_view.getNPages();
        const current = tab_view.getPagePosition(source_page);

        var create_destination = false;
        const destination_pos: c_int = switch (target) {
            .previous => previous: {
                if (total <= 1) {
                    self.addToast(i18n._("No other workspace to move the pane into"));
                    return false;
                }
                break :previous if (current > 0)
                    current - 1
                else
                    total - 1;
            },

            .next => next: {
                if (total <= 1) {
                    self.addToast(i18n._("No other workspace to move the pane into"));
                    return false;
                }
                break :next if (current < total - 1)
                    current + 1
                else
                    0;
            },

            .last => last: {
                if (total <= 1) {
                    self.addToast(i18n._("No other tab to move the pane into"));
                    return false;
                }
                break :last total - 1;
            },

            .n => |v| n: {
                if (v == 0) {
                    self.addToast(i18n._("Invalid workspace index"));
                    return false;
                }
                const n_int = std.math.cast(c_int, v) orelse {
                    self.addToast(i18n._("Invalid workspace index"));
                    return false;
                };
                if (n_int > total) {
                    create_destination = true;
                    break :n total;
                }
                break :n n_int - 1;
            },
        };
        if (!create_destination and destination_pos == current) {
            self.addToast(i18n._("Pane is already in that workspace"));
            return false;
        }

        const destination_page = if (create_destination)
            self.newEmptyWorkspacePage(destination_pos, true)
        else
            tab_view.getNthPage(destination_pos);
        const destination_workspace_page = gobject.ext.cast(
            WorkspacePage,
            destination_page.getChild(),
        ) orelse return false;

        const source_tree = source_workspace_page.getSplitTree();
        const destination_tree = destination_workspace_page.getSplitTree();

        _ = surface.ref();
        defer surface.unref();

        if (!source_tree.removeSurface(surface)) {
            self.addToast(i18n._("Unable to move pane to that workspace"));
            return false;
        }

        destination_tree.addExistingSurface(.right, surface) catch |err| {
            log.warn("unable to move surface into destination workspace: {}", .{err});
            source_tree.addExistingSurface(.right, surface) catch |restore_err| {
                log.warn("unable to restore moved surface after failed move: {}", .{restore_err});
            };
            if (create_destination) tab_view.closePage(destination_page);
            self.addToast(i18n._("Unable to move pane to that workspace"));
            return false;
        };

        if (!source_tree.getHasSurfaces()) {
            tab_view.closePage(source_page);
        }

        tab_view.setSelectedPage(tab_view.getPage(destination_workspace_page.as(gtk.Widget)));
        surface.grabFocus();
        return true;
    }

    pub fn moveSurfaceToTab(
        self: *Self,
        surface: *Surface,
        target: SelectTab,
    ) bool {
        return self.moveSurfaceToWorkspace(surface, target);
    }

    pub fn toggleWorkspaceSidebar(self: *Self) void {
        const priv = self.private();
        const split_view = priv.workspace_split_view;
        if (split_view.getStartChild() != null) {
            const pos = split_view.getPosition();
            if (pos > 0) priv.workspace_sidebar_position = pos;
            split_view.setStartChild(null);
            return;
        }

        split_view.setStartChild(priv.workspace_sidebar.as(gtk.Widget));
        split_view.setPosition(priv.workspace_sidebar_position);
    }

    pub fn toggleTabOverview(self: *Self) void {
        self.toggleWorkspaceSidebar();
    }

    fn workspaceSidebarWorkspaceSelected(_: *WorkspaceSidebar, workspace_page: *WorkspacePage, self: *Self) callconv(.c) void {
        const priv = self.private();
        const page = priv.tab_view.getPage(workspace_page.as(gtk.Widget));
        if (priv.tab_view.getSelectedPage() != page) {
            priv.tab_view.setSelectedPage(page);
        }
        self.focusWorkspaceSelection(workspace_page);
    }

    fn workspaceSidebarNewWorkspace(_: *WorkspaceSidebar, self: *Self) callconv(.c) void {
        self.newWorkspace(if (self.getActiveSurface()) |surface| surface.core() else null);
    }

    fn workspaceSidebarPromptWorkspaceTitle(_: *WorkspaceSidebar, workspace_page: *WorkspacePage, _: *Self) callconv(.c) void {
        queueWorkspacePageIdleAction(workspace_page, .prompt_title);
    }

    fn workspaceSidebarSaveWorkspace(_: *WorkspaceSidebar, workspace_page: *WorkspacePage, _: *Self) callconv(.c) void {
        queueWorkspacePageIdleAction(workspace_page, .save);
    }

    fn workspaceSidebarRevealWorkspaceSnapshot(_: *WorkspaceSidebar, workspace_page: *WorkspacePage, _: *Self) callconv(.c) void {
        queueWorkspacePageIdleAction(workspace_page, .reveal_snapshot);
    }

    fn workspaceSidebarOpenWorkspaceSnapshot(_: *WorkspaceSidebar, workspace_page: *WorkspacePage, _: *Self) callconv(.c) void {
        queueWorkspacePageIdleAction(workspace_page, .open_snapshot);
    }

    fn workspaceSidebarDeleteWorkspace(_: *WorkspaceSidebar, workspace_page: *WorkspacePage, _: *Self) callconv(.c) void {
        queueWorkspacePageIdleAction(workspace_page, .delete_snapshot);
    }

    fn workspaceSidebarCloseWorkspace(_: *WorkspaceSidebar, workspace_page: *WorkspacePage, _: *Self) callconv(.c) void {
        queueWorkspacePageIdleAction(workspace_page, .close);
    }

    fn workspaceSidebarRestoreWorkspace(_: *WorkspaceSidebar, self: *Self) callconv(.c) void {
        _ = self.ref();
        _ = glib.idleAdd(idleShowRestoreWorkspaceCommands, self);
    }

    fn syncWorkspaceSidebarSelection(self: *Self) void {
        const priv = self.private();
        const page = priv.tab_view.getSelectedPage() orelse {
            priv.workspace_sidebar.syncSelection(null);
            return;
        };
        const idx = priv.tab_view.getPagePosition(page);
        priv.workspace_sidebar.syncSelection(idx);
    }

    /// Toggle the visible property.
    pub fn toggleVisibility(self: *Self) void {
        const widget = self.as(gtk.Widget);
        widget.setVisible(@intFromBool(widget.isVisible() == 0));
    }

    /// Updates various appearance properties. This should always be safe
    /// to call multiple times. This should be called whenever a change
    /// happens that might affect how the window appears (config change,
    /// fullscreen, etc.).
    fn syncAppearance(self: *Self) void {
        const priv = self.private();
        const widget = self.as(gtk.Widget);

        // Toggle style classes based on whether we're using CSDs or SSDs.
        //
        // These classes are defined in the gtk.Window documentation:
        // https://docs.gtk.org/gtk4/class.Window.html#css-nodes.
        {
            // Reset all style classes first
            inline for (&.{
                "ssd",
                "csd",
                "solid-csd",
                "no-border-radius",
            }) |class|
                widget.removeCssClass(class);

            const csd_enabled = priv.winproto.clientSideDecorationEnabled();
            self.as(gtk.Window).setDecorated(@intFromBool(csd_enabled));

            if (csd_enabled) {
                const display = widget.getDisplay();

                // We do the exact same check GTK is doing internally and toggle
                // either the `csd` or `solid-csd` style, based on whether the user's
                // window manager is deemed _non-compositing_.
                //
                // In practice this only impacts users of traditional X11 window
                // managers (e.g. i3, dwm, awesomewm, etc.) and not X11 desktop
                // environments or Wayland compositors/DEs.
                if (display.isRgba() != 0 and display.isComposited() != 0) {
                    widget.addCssClass("csd");
                } else {
                    widget.addCssClass("solid-csd");
                }
            } else {
                widget.addCssClass("ssd");
                // Fix any artifacting that may occur in window corners.
                widget.addCssClass("no-border-radius");
            }
        }

        // Trigger all our dynamic properties that depend on the config.
        inline for (&.{
            "headerbar-visible",
            "tabs-autohide",
            "tabs-visible",
            "tabs-wide",
            "toolbar-style",
            "titlebar-style",
        }) |key| {
            self.as(gobject.Object).notifyByPspec(
                @field(properties, key).impl.param_spec,
            );
        }

        // Remainder uses the config
        const config = if (priv.config) |v| v.get() else return;

        // Only add a solid background if we're opaque.
        self.toggleCssClass(
            "background",
            config.@"background-opacity" >= 1,
        );

        // Apply class to color headerbar if window-theme is set to `ghostty` and
        // GTK version is before 4.16. The conditional is because above 4.16
        // we use GTK CSS color variables.
        self.toggleCssClass(
            "window-theme-ghostty",
            !gtk_version.atLeast(4, 16, 0) and
                config.@"window-theme" == .ghostty,
        );

        // Move the tab bar to the proper location.
        priv.toolbar.remove(priv.tab_bar.as(gtk.Widget));
        switch (config.@"gtk-tabs-location") {
            .top => priv.toolbar.addTopBar(priv.tab_bar.as(gtk.Widget)),
            .bottom => priv.toolbar.addBottomBar(priv.tab_bar.as(gtk.Widget)),
        }

        // Do our window-protocol specific appearance sync.
        priv.winproto.syncAppearance() catch |err| {
            log.warn("failed to sync winproto appearance error={}", .{err});
        };
    }

    /// Sync the state of any actions on this window.
    fn syncActions(self: *Self) void {
        const has_selection = selection: {
            const surface = self.getActiveSurface() orelse
                break :selection false;
            const core_surface = surface.core() orelse
                break :selection false;
            break :selection core_surface.hasSelection();
        };

        const action_map: *gio.ActionMap = gobject.ext.cast(
            gio.ActionMap,
            self,
        ) orelse return;
        const action: *gio.SimpleAction = gobject.ext.cast(
            gio.SimpleAction,
            action_map.lookupAction("copy") orelse return,
        ) orelse return;
        action.setEnabled(@intFromBool(has_selection));
    }

    fn toggleCssClass(self: *Self, class: [:0]const u8, value: bool) void {
        const widget = self.as(gtk.Widget);
        if (value)
            widget.addCssClass(class.ptr)
        else
            widget.removeCssClass(class.ptr);
    }

    /// Perform a binding action on the window's active surface.
    fn performBindingAction(
        self: *Self,
        action: input.Binding.Action,
    ) void {
        const surface = self.getActiveSurface() orelse return;
        const core_surface = surface.core() orelse return;
        _ = core_surface.performBindingAction(action) catch |err| {
            log.warn("error performing binding action error={}", .{err});
            return;
        };
    }

    /// Queue a simple text-based toast. All text-based toasts share the
    /// same timeout for consistency.
    ///
    // This is not `pub` because we should be using signals emitted by
    // other widgets to trigger our toasts. Other objects should not
    // trigger toasts directly.
    fn addToast(self: *Self, title: [*:0]const u8) void {
        const toast = adw.Toast.new(title);
        toast.setTimeout(3);
        self.private().toast_overlay.addToast(toast);
    }

    fn connectSurfaceHandler(self: *Self, surface: *Surface) void {
        const priv = self.private();
        const tab = ext.getAncestor(Tab, surface.as(gtk.Widget));

        _ = gobject.signalHandlersDisconnectMatched(
            surface.as(gobject.Object),
            .{ .data = true },
            0,
            0,
            null,
            null,
            self,
        );
        if (tab) |t| {
            _ = gobject.signalHandlersDisconnectMatched(
                t.as(gobject.Object),
                .{ .data = true },
                0,
                0,
                null,
                null,
                self,
            );
        }

        _ = Surface.signals.@"present-request".connect(
            surface,
            *Self,
            surfacePresentRequest,
            self,
            .{},
        );
        _ = Surface.signals.@"clipboard-write".connect(
            surface,
            *Self,
            surfaceClipboardWrite,
            self,
            .{},
        );
        _ = Surface.signals.menu.connect(
            surface,
            *Self,
            surfaceMenu,
            self,
            .{},
        );
        _ = Surface.signals.@"toggle-fullscreen".connect(
            surface,
            *Self,
            surfaceToggleFullscreen,
            self,
            .{},
        );
        _ = Surface.signals.@"toggle-maximize".connect(
            surface,
            *Self,
            surfaceToggleMaximize,
            self,
            .{},
        );
        _ = gobject.Object.signals.notify.connect(
            surface.as(gobject.Object),
            *Self,
            surfaceRuntimeStateChanged,
            self,
            .{ .detail = "focused" },
        );
        _ = gobject.Object.signals.notify.connect(
            surface.as(gobject.Object),
            *Self,
            surfaceRuntimeStateChanged,
            self,
            .{ .detail = "title" },
        );
        _ = gobject.Object.signals.notify.connect(
            surface.as(gobject.Object),
            *Self,
            surfaceRuntimeStateChanged,
            self,
            .{ .detail = "pwd" },
        );
        _ = gobject.Object.signals.notify.connect(
            surface.as(gobject.Object),
            *Self,
            surfaceRuntimeStateChanged,
            self,
            .{ .detail = "bell-ringing" },
        );
        _ = gobject.Object.signals.notify.connect(
            surface.as(gobject.Object),
            *Self,
            surfaceRuntimeStateChanged,
            self,
            .{ .detail = "unread-pending" },
        );
        _ = gobject.Object.signals.notify.connect(
            surface.as(gobject.Object),
            *Self,
            surfaceRuntimeStateChanged,
            self,
            .{ .detail = "child-exited" },
        );
        _ = gobject.Object.signals.notify.connect(
            surface.as(gobject.Object),
            *Self,
            surfaceRestorableStateChanged,
            self,
            .{ .detail = "title-override" },
        );
        if (tab) |t| {
            _ = gobject.Object.signals.notify.connect(
                t.as(gobject.Object),
                *Self,
                tabRestorableStateChanged,
                self,
                .{ .detail = "title-override" },
            );
        }

        if (!priv.surface_init) {
            _ = Surface.signals.init.connect(
                surface,
                *Self,
                surfaceInit,
                self,
                .{},
            );
        }
    }

    fn connectSurfaceHandlers(
        self: *Self,
        tree: *const SplitTabs.Tree,
    ) void {
        var it = tree.iterator();
        while (it.next()) |entry| {
            const leaf = entry.view;
            const n = leaf.getSurfaceCount();
            for (0..@intCast(n)) |i| {
                const surface = leaf.getSurfaceAt(@intCast(i)) orelse continue;
                self.connectSurfaceHandler(surface);
            }
        }
    }

    /// Disconnect all the surface handlers for the given tree. This should
    /// be called whenever a tree is no longer present in the window, e.g.
    /// when a tab is detached or the tree changes.
    fn disconnectSurfaceHandlers(
        self: *Self,
        tree: *const SplitTabs.Tree,
    ) void {
        var it = tree.iterator();
        while (it.next()) |entry| {
            const leaf = entry.view;
            const n = leaf.getSurfaceCount();
            for (0..@intCast(n)) |i| {
                const surface = leaf.getSurfaceAt(@intCast(i)) orelse continue;
                if (ext.getAncestor(Tab, surface.as(gtk.Widget))) |tab| {
                    _ = gobject.signalHandlersDisconnectMatched(
                        tab.as(gobject.Object),
                        .{ .data = true },
                        0,
                        0,
                        null,
                        null,
                        self,
                    );
                }
                _ = gobject.signalHandlersDisconnectMatched(
                    surface.as(gobject.Object),
                    .{ .data = true },
                    0,
                    0,
                    null,
                    null,
                    self,
                );
            }
        }
    }

    /// Callback to handle this window becoming active or inactive.
    /// Triggered by propIsActive with a timeout to debounce temporary
    /// changes in active state.
    fn handleActiveState(ud: ?*anyopaque) callconv(.c) c_int {
        const self: *Self = @ptrCast(@alignCast(ud orelse return 0));
        const priv = self.private();
        priv.handle_active_state_source = null;

        // Hide quick-terminal if set to autohide
        if (self.isQuickTerminal()) {
            if (self.getConfig()) |cfg| {
                if (cfg.get().@"quick-terminal-autohide" and
                    self.as(gtk.Window).isActive() == 0 and
                    self.as(gtk.Widget).isVisible() == 1)
                {
                    self.toggleVisibility();
                }
            }
        }

        // Don't change urgency if we're not the active window.
        if (self.as(gtk.Window).isActive() == 0) return 0;

        self.winproto().setUrgent(false) catch |err| {
            log.warn(
                "winproto failed to reset urgency={}",
                .{err},
            );
        };
        return 0;
    }

    //---------------------------------------------------------------
    // Properties

    /// Whether this terminal is a quick terminal or not.
    pub fn isQuickTerminal(self: *Self) bool {
        return self.private().quick_terminal;
    }

    /// Get the currently active surface. See the "active-surface" property.
    /// This does not ref the value.
    pub fn getActiveSurface(self: *Self) ?*Surface {
        const workspace_page = self.getSelectedWorkspacePage() orelse return null;
        return workspace_page.getActiveSurface();
    }

    /// Returns the configuration for this window. The reference count
    /// is not increased.
    pub fn getConfig(self: *Self) ?*Config {
        return self.private().config;
    }

    /// Get the tab view for this window.
    pub fn getTabView(self: *Self) *adw.TabView {
        return self.private().tab_view;
    }

    /// Get the current window decoration value for this window.
    pub fn getWindowDecoration(self: *Self) configpkg.WindowDecoration {
        const priv = self.private();
        if (priv.window_decoration) |v| return v;
        if (priv.config) |v| return v.get().@"window-decoration";
        return .auto;
    }

    /// Toggle the window decorations for this window.
    pub fn toggleWindowDecorations(self: *Self) void {
        const priv = self.private();

        if (priv.window_decoration) |_| {
            // Unset any previously set window decoration settings
            self.setWindowDecoration(null);
            return;
        }

        const config = if (priv.config) |v| v.get() else return;
        self.setWindowDecoration(switch (config.@"window-decoration") {
            // Use auto when the decoration is initially none
            .none => .auto,

            // Anything non-none to none
            .auto, .client, .server => .none,
        });
    }

    /// Set the window decoration override for this window. If this is null,
    /// then we'll revert back to the configuration's default.
    fn setWindowDecoration(
        self: *Self,
        new_: ?configpkg.WindowDecoration,
    ) void {
        const priv = self.private();
        priv.window_decoration = new_;
        self.syncAppearance();
    }

    /// Get the currently selected workspace page.
    fn getSelectedWorkspacePage(self: *Self) ?*WorkspacePage {
        const priv = self.private();
        const page = priv.tab_view.getSelectedPage() orelse return null;
        const child = page.getChild();
        assert(gobject.ext.isA(child, WorkspacePage));
        return gobject.ext.cast(WorkspacePage, child);
    }

    fn findWorkspacePageByRuntimeId(
        self: *Self,
        workspace_id: workspace_ids.WorkspaceId,
    ) ?*WorkspacePage {
        const priv = self.private();
        const page_count = priv.tab_view.getNPages();
        for (0..@intCast(page_count)) |i| {
            const page = priv.tab_view.getNthPage(@intCast(i));
            const child = page.getChild();
            const workspace_page = gobject.ext.cast(WorkspacePage, child) orelse continue;
            const mapped_id = priv.workspace_ids_by_page.get(ptrKey(workspace_page)) orelse continue;
            if (mapped_id == workspace_id) return workspace_page;
        }
        return null;
    }

    pub fn getWorkspaceRegistry(self: *Self) *workspace_registry.Registry {
        return &self.private().runtime_registry;
    }

    const WorkspaceLayoutProjection = struct {
        layout_root_id: []const u8,
        representative_split_id: workspace_ids.SplitId,
        contains_selected_split: bool,
    };

    const WorkspaceLeafLayoutRef = struct {
        split_id: workspace_ids.SplitId,
        layout_root_id: []const u8,
        is_selected: bool,
    };

    fn workspaceLayoutDirection(
        layout: SplitTabs.Tree.Split.Layout,
    ) workspace_model.SplitDirection {
        return switch (layout) {
            .horizontal => .right,
            .vertical => .down,
        };
    }

    fn appendWorkspaceLayoutProjection(
        self: *Self,
        runtime: *workspace_registry.WorkspaceRuntime,
        tree: *const SplitTabs.Tree,
        handle: SplitTabs.Tree.Node.Handle,
        leaf_layout_by_handle: *const std.AutoHashMap(usize, WorkspaceLeafLayoutRef),
    ) !WorkspaceLayoutProjection {
        const node = tree.nodes[handle.idx()];
        return switch (node) {
            .leaf => blk: {
                const leaf_ref = leaf_layout_by_handle.get(handle.idx()) orelse return error.WorkspaceLayoutLeafMissing;
                break :blk .{
                    .layout_root_id = leaf_ref.layout_root_id,
                    .representative_split_id = leaf_ref.split_id,
                    .contains_selected_split = leaf_ref.is_selected,
                };
            },
            .split => |split| blk: {
                const left = try appendWorkspaceLayoutProjection(
                    self,
                    runtime,
                    tree,
                    split.left,
                    leaf_layout_by_handle,
                );
                const right = try appendWorkspaceLayoutProjection(
                    self,
                    runtime,
                    tree,
                    split.right,
                    leaf_layout_by_handle,
                );
                const contains_selected_split = left.contains_selected_split or right.contains_selected_split;
                const representative_split_id = if (left.contains_selected_split)
                    left.representative_split_id
                else if (right.contains_selected_split)
                    right.representative_split_id
                else
                    left.representative_split_id;
                const layout_root_id = try std.fmt.allocPrint(
                    runtime.runtimeAllocator(),
                    "workspace-layout-{d}-{d}",
                    .{ runtime.workspace.workspace_id.raw(), handle.idx() },
                );
                try runtime.layout.append(Application.default().allocator(), .{
                    .layout_node_id = layout_root_id,
                    .workspace_id = runtime.workspace.workspace_id,
                    .split_id = representative_split_id,
                    .tab_id = null,
                    .node_type = .split,
                    .split_direction = workspaceLayoutDirection(split.layout),
                    .ratio = split.ratio,
                    .child_ids = try runtime.runtimeAllocator().dupe(
                        []const u8,
                        &.{ left.layout_root_id, right.layout_root_id },
                    ),
                    .is_selected = contains_selected_split,
                });
                break :blk .{
                    .layout_root_id = layout_root_id,
                    .representative_split_id = representative_split_id,
                    .contains_selected_split = contains_selected_split,
                };
            },
        };
    }

    fn refreshWorkspaceRegistry(self: *Self) !void {
        const priv = self.private();
        const alloc = Application.default().allocator();
        const n = priv.tab_view.getNPages();

        var live_workspace_keys: std.ArrayList(usize) = .empty;
        defer live_workspace_keys.deinit(alloc);
        var live_split_keys: std.ArrayList(usize) = .empty;
        defer live_split_keys.deinit(alloc);
        var live_tab_keys: std.ArrayList(usize) = .empty;
        defer live_tab_keys.deinit(alloc);
        var live_surface_keys: std.ArrayList(usize) = .empty;
        defer live_surface_keys.deinit(alloc);
        var live_session_ids: std.ArrayList(workspace_ids.SessionId) = .empty;
        defer live_session_ids.deinit(alloc);

        for (0..@intCast(n)) |i| {
            const page = priv.tab_view.getNthPage(@intCast(i));
            const child = page.getChild();
            const workspace_page = gobject.ext.cast(WorkspacePage, child) orelse continue;
            const workspace_key = ptrKey(workspace_page);
            try live_workspace_keys.append(alloc, workspace_key);

            const runtime = try self.getOrCreateWorkspaceRuntime(workspace_page);
            runtime.resetRuntime();
            try self.updateWorkspaceMetadata(runtime, workspace_page);
            try self.appendWindowRuntime(runtime);

            const active_surface = workspace_page.getActiveSurface();
            const tree = workspace_page.getSurfaceTree() orelse {
                runtime.workspace.selected_window_id = priv.runtime_window_id;
                continue;
            };

            var split_ids: std.ArrayList(workspace_ids.SplitId) = .empty;
            defer split_ids.deinit(alloc);
            var tab_ids: std.ArrayList(workspace_ids.TabId) = .empty;
            defer tab_ids.deinit(alloc);
            var session_ids: std.ArrayList(workspace_ids.SessionId) = .empty;
            defer session_ids.deinit(alloc);
            var leaf_layout_by_handle = std.AutoHashMap(usize, WorkspaceLeafLayoutRef).init(alloc);
            defer leaf_layout_by_handle.deinit();

            var it = tree.iterator();
            var split_ordinal: usize = 0;
            while (it.next()) |entry| {
                const leaf = entry.view;
                const split_key = ptrKey(leaf);
                try live_split_keys.append(alloc, split_key);
                const split_id = try self.getOrCreateSplitId(leaf);
                try split_ids.append(alloc, split_id);

                const split_selected = if (active_surface) |surface|
                    leaf.containsSurface(surface)
                else
                    false;
                if (split_selected) runtime.workspace.selected_split_id = split_id;

                const split_root_id = try std.fmt.allocPrint(
                    runtime.runtimeAllocator(),
                    "split-root-{d}",
                    .{split_id.raw()},
                );
                var split_tab_ids: std.ArrayList(workspace_ids.TabId) = .empty;
                defer split_tab_ids.deinit(alloc);
                var split_child_ids: std.ArrayList([]const u8) = .empty;
                defer split_child_ids.deinit(alloc);
                var split_attention: workspace_attention.AttentionSummary = .{};

                const tab_count = leaf.getTabCount();
                for (0..@intCast(tab_count)) |tab_index| {
                    const tab = leaf.getTabAt(@intCast(tab_index)) orelse continue;
                    const surface = tab.getSurface() orelse continue;
                    const tab_key = ptrKey(tab);
                    const surface_key = ptrKey(surface);
                    try live_tab_keys.append(alloc, tab_key);
                    try live_surface_keys.append(alloc, surface_key);

                    const tab_id = try self.getOrCreateTabId(tab);
                    const surface_id = try self.getOrCreateSurfaceId(surface);
                    try split_tab_ids.append(alloc, tab_id);
                    try tab_ids.append(alloc, tab_id);

                    const tab_root_id = try std.fmt.allocPrint(
                        runtime.runtimeAllocator(),
                        "tab-root-{d}",
                        .{tab_id.raw()},
                    );
                    try split_child_ids.append(alloc, tab_root_id);

                    const session_path = try std.fmt.allocPrint(
                        runtime.runtimeAllocator(),
                        "ws-{d}/split-{d}/tab-{d}",
                        .{
                            runtime.workspace.workspace_id.raw(),
                            split_id.raw(),
                            tab_id.raw(),
                        },
                    );
                    const session_id = try priv.session_identity_index.resolvePath(
                        Application.default().runtimeIds(),
                        session_path,
                    );
                    try priv.session_identity_index.bindSession(session_id, surface_key, session_path);
                    try session_ids.append(alloc, session_id);
                    try live_session_ids.append(alloc, session_id);

                    const title = surface.getEffectiveTitle() orelse tab.getEffectiveTitle() orelse "Ghostty";
                    const tooltip = tab.getTooltip() orelse surface.getPwd();
                    const session_leaf_id = try std.fmt.allocPrint(
                        runtime.runtimeAllocator(),
                        "session-leaf-{d}",
                        .{session_id.raw()},
                    );
                    const selected_tab = if (active_surface) |selected|
                        selected == surface
                    else
                        false;

                    if (selected_tab) {
                        runtime.workspace.selected_tab_id = tab_id;
                        runtime.workspace.selected_session_id = session_id;
                    }

                    const bell_ringing = surface.getBellRinging();
                    const unread_pending = surface.getUnreadPending() or bell_ringing;
                    const activity_state: workspace_model.ActivityState = if (bell_ringing)
                        .bell_pending
                    else if (unread_pending)
                        .output_pending
                    else if (surface.getChildExited())
                        .exited
                    else
                        .idle;

                    try runtime.tabs.append(alloc, .{
                        .tab_id = tab_id,
                        .split_id = split_id,
                        .workspace_id = runtime.workspace.workspace_id,
                        .window_id = priv.runtime_window_id.?,
                        .title = title,
                        .title_override = tab.getTitleOverride(),
                        .tooltip = tooltip,
                        .layout_root_id = tab_root_id,
                        .ordinal = tab_index,
                        .needs_attention = unread_pending,
                    });
                    try runtime.layout.append(alloc, .{
                        .layout_node_id = tab_root_id,
                        .workspace_id = runtime.workspace.workspace_id,
                        .split_id = split_id,
                        .tab_id = tab_id,
                        .node_type = .tab,
                        .child_ids = try runtime.runtimeAllocator().dupe([]const u8, &.{session_leaf_id}),
                        .is_selected = selected_tab,
                    });
                    try runtime.layout.append(alloc, .{
                        .layout_node_id = session_leaf_id,
                        .workspace_id = runtime.workspace.workspace_id,
                        .split_id = split_id,
                        .tab_id = tab_id,
                        .node_type = .session_leaf,
                        .session_id = session_id,
                        .is_selected = selected_tab,
                    });
                    var launch_command = try surface.cloneLaunchCommand(runtime.runtimeAllocator());
                    defer if (launch_command) |*command| command.deinit(runtime.runtimeAllocator());

                    try runtime.sessions.append(alloc, .{
                        .session_id = session_id,
                        .workspace_id = runtime.workspace.workspace_id,
                        .window_id = priv.runtime_window_id.?,
                        .tab_id = tab_id,
                        .split_id = split_id,
                        .layout_node_id = session_leaf_id,
                        .title = title,
                        .title_override = surface.getTitleOverride(),
                        .cwd = surface.getPwd() orelse "",
                        .command = try workspaceModelCommandFromSurfaceAlloc(
                            runtime.runtimeAllocator(),
                            launch_command,
                        ),
                        .focus_state = if (surface.getFocused())
                            .focused
                        else if (selected_tab)
                            .last_focused
                        else
                            .background,
                        .activity_state = activity_state,
                        .last_output_at = surface.getLastOutputAt(),
                    });
                    try runtime.surfaces.append(alloc, .{
                        .surface_id = surface_id,
                        .session_id = session_id,
                        .tab_id = tab_id,
                        .split_id = split_id,
                        .window_id = priv.runtime_window_id.?,
                        .is_realized = surface.as(gtk.Widget).getRealized() != 0,
                        .last_bell_at = surface.getLastBellAt(),
                        .last_output_at = surface.getLastOutputAt(),
                    });

                    split_attention.include(.{
                        .target_id = .{ .session = session_id },
                        .unread = unread_pending,
                        .bell = bell_ringing,
                    });
                }

                try runtime.splits.append(alloc, .{
                    .split_id = split_id,
                    .workspace_id = runtime.workspace.workspace_id,
                    .window_id = priv.runtime_window_id.?,
                    .title = leaf.splitTreeLabel(),
                    .ordinal = split_ordinal,
                    .tab_ids = try runtime.runtimeAllocator().dupe(workspace_ids.TabId, split_tab_ids.items),
                    .layout_root_id = split_root_id,
                    .needs_attention = split_attention.needs_attention,
                });
                try runtime.layout.append(alloc, .{
                    .layout_node_id = split_root_id,
                    .workspace_id = runtime.workspace.workspace_id,
                    .split_id = split_id,
                    .tab_id = if (split_tab_ids.items.len > 0) split_tab_ids.items[0] else null,
                    .node_type = .split_root,
                    .child_ids = try runtime.runtimeAllocator().dupe([]const u8, split_child_ids.items),
                    .is_selected = split_selected,
                });
                try leaf_layout_by_handle.put(entry.handle.idx(), .{
                    .split_id = split_id,
                    .layout_root_id = split_root_id,
                    .is_selected = split_selected,
                });
                runtime.workspace.attention_summary.merge(split_attention);
                split_ordinal += 1;
            }

            if (tree.nodes.len > 0) {
                const projection = try self.appendWorkspaceLayoutProjection(
                    runtime,
                    tree,
                    .root,
                    &leaf_layout_by_handle,
                );
                runtime.workspace.layout_root_id = projection.layout_root_id;
            }

            runtime.workspace.selected_window_id = priv.runtime_window_id;
            runtime.workspace.split_ids = try runtime.runtimeAllocator().dupe(workspace_ids.SplitId, split_ids.items);
            runtime.workspace.tab_ids = try runtime.runtimeAllocator().dupe(workspace_ids.TabId, tab_ids.items);
            runtime.workspace.session_ids = try runtime.runtimeAllocator().dupe(workspace_ids.SessionId, session_ids.items);
            if (runtime.windows.items.len > 0) {
                runtime.windows.items[0].split_ids = try runtime.runtimeAllocator().dupe(
                    workspace_ids.SplitId,
                    split_ids.items,
                );
            }
        }

        try self.pruneWorkspaceRegistry(live_workspace_keys.items);
        pruneIdMap(workspace_ids.SplitId, &priv.split_ids_by_leaf, live_split_keys.items);
        pruneIdMap(workspace_ids.TabId, &priv.tab_ids_by_widget, live_tab_keys.items);
        pruneIdMap(workspace_ids.SurfaceId, &priv.surface_ids_by_widget, live_surface_keys.items);
        try priv.session_identity_index.pruneAttachments(live_surface_keys.items);
        pruneSavedScrollbackStates(
            Application.default().allocator(),
            &priv.scrollback_saved_states,
            live_session_ids.items,
        );
    }

    fn getOrCreateWorkspaceRuntime(self: *Self, workspace_page: *WorkspacePage) !*workspace_registry.WorkspaceRuntime {
        const priv = self.private();
        const key = ptrKey(workspace_page);
        if (priv.workspace_ids_by_page.get(key)) |workspace_id| {
            if (priv.runtime_registry.findWorkspace(workspace_id)) |runtime| {
                return runtime;
            }
            _ = priv.workspace_ids_by_page.remove(key);
        }

        const title = workspace_page.getSidebarTitle() orelse workspace_page.getTitleOverride() orelse "workspace";
        const created_at = try allocUtcTimestamp(Application.default().allocator());
        defer Application.default().allocator().free(created_at);
        const title_text: []const u8 = title;
        const workspace_id = Application.default().runtimeIds().next(.workspace);
        const workspace_key = try allocFreshWorkspaceKey(workspace_id);
        defer Application.default().allocator().free(workspace_key);
        const runtime = try priv.runtime_registry.createWorkspaceWithId(
            workspace_id,
            title_text,
            workspace_key,
            created_at,
        );
        try priv.workspace_ids_by_page.put(key, runtime.workspace.workspace_id);
        return runtime;
    }

    fn updateWorkspaceMetadata(
        _: *Self,
        runtime: *workspace_registry.WorkspaceRuntime,
        workspace_page: *WorkspacePage,
    ) !void {
        const alloc = Application.default().allocator();
        const title = workspace_page.getSidebarTitle() orelse workspace_page.getTitleOverride() orelse "workspace";
        const title_text: []const u8 = title;
        const updated_at = try allocUtcTimestamp(alloc);

        alloc.free(runtime.workspace.name);
        alloc.free(runtime.workspace.updated_at);
        runtime.workspace.name = try alloc.dupe(u8, title_text);
        runtime.workspace.updated_at = updated_at;
        runtime.workspace.attention_summary = .{};
        runtime.workspace.selected_window_id = null;
        runtime.workspace.selected_split_id = null;
        runtime.workspace.selected_tab_id = null;
        runtime.workspace.selected_session_id = null;
    }

    fn appendWindowRuntime(self: *Self, runtime: *workspace_registry.WorkspaceRuntime) !void {
        const priv = self.private();
        if (priv.runtime_window_id == null) {
            priv.runtime_window_id = Application.default().runtimeIds().next(.window);
        }
        try runtime.windows.append(Application.default().allocator(), .{
            .window_id = priv.runtime_window_id.?,
            .workspace_id = runtime.workspace.workspace_id,
            .is_active = self.as(gtk.Window).isActive() != 0,
            .is_quick_terminal = self.isQuickTerminal(),
        });
    }

    fn pruneWorkspaceRegistry(self: *Self, live_workspace_keys: []const usize) !void {
        const alloc = Application.default().allocator();
        const priv = self.private();
        var stale_workspace_keys: std.ArrayList(usize) = .empty;
        defer stale_workspace_keys.deinit(alloc);

        var it = priv.workspace_ids_by_page.iterator();
        while (it.next()) |entry| {
            if (containsUsize(live_workspace_keys, entry.key_ptr.*)) continue;
            try stale_workspace_keys.append(alloc, entry.key_ptr.*);
        }

        for (stale_workspace_keys.items) |key| {
            const workspace_id = priv.workspace_ids_by_page.get(key) orelse continue;
            _ = priv.runtime_registry.removeWorkspace(workspace_id);
            _ = priv.workspace_ids_by_page.remove(key);
        }
    }

    fn getOrCreateSplitId(self: *Self, leaf: *SplitTabs) !workspace_ids.SplitId {
        const priv = self.private();
        const key = ptrKey(leaf);
        if (priv.split_ids_by_leaf.get(key)) |id| return id;
        const id = Application.default().runtimeIds().next(.split);
        try priv.split_ids_by_leaf.put(key, id);
        return id;
    }

    fn getOrCreateTabId(self: *Self, tab: *Tab) !workspace_ids.TabId {
        const priv = self.private();
        const key = ptrKey(tab);
        if (priv.tab_ids_by_widget.get(key)) |id| return id;
        const id = Application.default().runtimeIds().next(.tab);
        try priv.tab_ids_by_widget.put(key, id);
        return id;
    }

    fn getOrCreateSurfaceId(self: *Self, surface: *Surface) !workspace_ids.SurfaceId {
        const priv = self.private();
        const key = ptrKey(surface);
        if (priv.surface_ids_by_widget.get(key)) |id| return id;
        const id = Application.default().runtimeIds().next(.surface);
        try priv.surface_ids_by_widget.put(key, id);
        return id;
    }

    fn ptrKey(ptr: anytype) usize {
        return @intFromPtr(ptr);
    }

    fn containsUsize(items: []const usize, needle: usize) bool {
        for (items) |item| {
            if (item == needle) return true;
        }
        return false;
    }

    fn pruneIdMap(
        comptime T: type,
        map: *std.AutoHashMap(usize, T),
        live_keys: []const usize,
    ) void {
        const alloc = Application.default().allocator();
        var stale_keys: std.ArrayList(usize) = .empty;
        defer stale_keys.deinit(alloc);

        var it = map.iterator();
        while (it.next()) |entry| {
            if (containsUsize(live_keys, entry.key_ptr.*)) continue;
            stale_keys.append(alloc, entry.key_ptr.*) catch continue;
        }

        for (stale_keys.items) |key| {
            _ = map.remove(key);
        }
    }

    fn allocUtcTimestamp(alloc: std.mem.Allocator) ![]u8 {
        const unix_seconds = std.time.timestamp();
        if (unix_seconds < 0) return error.UnsupportedTimestamp;

        const epoch_seconds = std.time.epoch.EpochSeconds{
            .secs = @as(u64, @intCast(unix_seconds)),
        };
        const epoch_day = epoch_seconds.getEpochDay();
        const year_day = epoch_day.calculateYearDay();
        const month_day = year_day.calculateMonthDay();
        const day_seconds = epoch_seconds.getDaySeconds();

        return std.fmt.allocPrint(alloc, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
            year_day.year,
            month_day.month.numeric(),
            month_day.day_index + 1,
            day_seconds.getHoursIntoDay(),
            day_seconds.getMinutesIntoHour(),
            day_seconds.getSecondsIntoMinute(),
        });
    }

    pub fn refreshWorkspaceRegistrySafe(self: *Self) void {
        if (self.private().disposing_runtime) return;
        self.refreshWorkspaceRegistry() catch |err| {
            log.warn("failed to refresh workspace registry error={}", .{err});
        };
        self.syncWorkspaceListDescriptors();
        self.syncWorkspaceListBadges();
    }

    pub fn getWorkspaceRuntimeForPage(
        self: *Self,
        workspace_page: *WorkspacePage,
    ) ?*workspace_registry.WorkspaceRuntime {
        const priv = self.private();
        const workspace_id = priv.workspace_ids_by_page.get(ptrKey(workspace_page)) orelse return null;
        if (priv.runtime_registry.findWorkspace(workspace_id)) |runtime| return runtime;
        _ = priv.workspace_ids_by_page.remove(ptrKey(workspace_page));
        return null;
    }

    fn focusWorkspaceSelection(self: *Self, workspace_page: *WorkspacePage) void {
        const runtime = self.getWorkspaceRuntimeForPage(workspace_page) orelse return;
        const route = workspace_registry.selectedSessionRoute(runtime) orelse {
            if (workspace_page.getActiveSurface()) |_| self.scheduleSurfaceFocus();
            return;
        };

        const tree = workspace_page.getSurfaceTree() orelse return;
        var it = tree.iterator();
        while (it.next()) |entry| {
            const leaf = entry.view;
            const n = leaf.getSurfaceCount();
            for (0..@intCast(n)) |i| {
                const surface = leaf.getSurfaceAt(@intCast(i)) orelse continue;
                const surface_key = ptrKey(surface);
                const candidate_session = self.private().session_identity_index.sessionForAttachment(surface_key) orelse continue;
                if (candidate_session != route.session_id) continue;
                _ = leaf.selectSurface(surface);
                self.scheduleSurfaceFocus();
                return;
            }
        }

        if (workspace_page.getActiveSurface()) |_| self.scheduleSurfaceFocus();
    }

    fn scheduleSurfaceFocus(self: *Self) void {
        const priv = self.private();
        if (priv.disposing_runtime) return;
        if (priv.pending_surface_focus_source) |source| {
            _ = glib.Source.remove(source);
            priv.pending_surface_focus_source = null;
        }
        priv.pending_surface_focus_source = glib.idleAdd(idleFocusSurface, self);
    }

    fn idleFocusSurface(ud: ?*anyopaque) callconv(.c) c_int {
        const self: *Self = @ptrCast(@alignCast(ud orelse return 0));
        const priv = self.private();
        priv.pending_surface_focus_source = null;
        if (priv.disposing_runtime) return 0;
        const surface = self.getActiveSurface() orelse return 0;
        surface.grabFocus();
        return 0;
    }

    fn scheduleWorkspaceAutosaveForWidget(self: *Self, widget: *gtk.Widget) void {
        const workspace_page = ext.getAncestor(WorkspacePage, widget) orelse return;
        self.scheduleWorkspaceAutosaveForPage(workspace_page);
    }

    fn scheduleWorkspaceAutosaveForPage(self: *Self, workspace_page: *WorkspacePage) void {
        const priv = self.private();
        if (priv.disposing_runtime) return;
        if (workspace_page.getSurfaceTree()) |tree| {
            if (tree.isEmpty()) return;
        } else {
            return;
        }

        if (priv.pending_workspace_autosave_source) |source| {
            _ = glib.Source.remove(source);
            priv.pending_workspace_autosave_source = null;
        }
        if (priv.pending_workspace_autosave_page) |page| {
            page.unref();
            priv.pending_workspace_autosave_page = null;
        }

        priv.pending_workspace_autosave_page = workspace_page.ref();
        priv.pending_workspace_autosave_source = glib.timeoutAdd(200, idleWorkspaceAutosave, self);
    }

    fn cancelPendingWorkspaceAutosave(self: *Self) void {
        const priv = self.private();
        if (priv.pending_workspace_autosave_source) |source| {
            _ = glib.Source.remove(source);
            priv.pending_workspace_autosave_source = null;
        }
        if (priv.pending_workspace_autosave_page) |workspace_page| {
            workspace_page.unref();
            priv.pending_workspace_autosave_page = null;
        }
    }

    fn idleWorkspaceAutosave(ud: ?*anyopaque) callconv(.c) c_int {
        const self: *Self = @ptrCast(@alignCast(ud orelse return 0));
        const priv = self.private();
        priv.pending_workspace_autosave_source = null;
        const workspace_page = priv.pending_workspace_autosave_page orelse return 0;
        priv.pending_workspace_autosave_page = null;
        defer workspace_page.unref();
        var scrollback_budget = AutosaveScrollbackBudget.init(
            workspacePageSurfaceCount(workspace_page),
        );
        self.autosaveWorkspacePage(
            workspace_page,
            .autosave,
            &scrollback_budget,
        );
        return 0;
    }

    fn periodicWorkspaceAutosave(ud: ?*anyopaque) callconv(.c) c_int {
        const self: *Self = @ptrCast(@alignCast(ud orelse return @intFromBool(glib.SOURCE_REMOVE)));
        const priv = self.private();
        if (priv.disposing_runtime) {
            priv.periodic_workspace_autosave_source = null;
            return @intFromBool(glib.SOURCE_REMOVE);
        }

        var scrollback_budget = AutosaveScrollbackBudget.init(
            self.savedWorkspaceSurfaceCount(),
        );
        self.autosaveSavedWorkspacePages(.autosave, &scrollback_budget);
        return @intFromBool(glib.SOURCE_CONTINUE);
    }

    fn autosaveWorkspacePage(
        self: *Self,
        workspace_page: *WorkspacePage,
        mode: WorkspaceSaveMode,
        autosave_scrollback_budget: ?*AutosaveScrollbackBudget,
    ) void {
        if (self.private().disposing_runtime) return;
        if (workspace_page.getSurfaceTree()) |tree| {
            if (tree.isEmpty()) return;
        } else {
            return;
        }
        self.refreshWorkspaceRegistrySafe();
        const runtime = self.getWorkspaceRuntimeForPage(workspace_page) orelse return;
        if (runtime.workspace.snapshot_ref == null) return;

        const alloc = Application.default().allocator();
        const result = saveWorkspaceWithModeAlloc(
            self,
            alloc,
            workspace_page,
            mode,
            autosave_scrollback_budget,
        ) catch |err| switch (err) {
            // During shutdown or structural page teardown, a saved workspace
            // can temporarily lose its selected tab/surface before the widget
            // graph is fully dismantled. Explicit save should still fail on
            // this, but autosave can safely skip the transient state.
            error.SelectionRequired,
            error.WorkspaceStorageBusy,
            => return,
            else => {
                log.warn("failed to autosave workspace error={}", .{err});
                return;
            },
        };
        result.deinit(alloc);
    }

    fn autosaveSavedWorkspacePages(
        self: *Self,
        mode: WorkspaceSaveMode,
        autosave_scrollback_budget: ?*AutosaveScrollbackBudget,
    ) void {
        const priv = self.private();
        const page_count = priv.tab_view.getNPages();
        for (0..@intCast(page_count)) |i| {
            const page = priv.tab_view.getNthPage(@intCast(i));
            const child = page.getChild();
            const workspace_page = gobject.ext.cast(WorkspacePage, child) orelse continue;
            self.autosaveWorkspacePage(
                workspace_page,
                mode,
                autosave_scrollback_budget,
            );
        }
    }

    pub fn autosaveAllWorkspacesOnShutdown(self: *Self) void {
        const priv = self.private();
        if (priv.shutdown_autosave_complete) return;
        priv.shutdown_autosave_complete = true;

        self.cancelPendingWorkspaceAutosave();
        self.autosaveSavedWorkspacePages(.shutdown, null);
    }

    fn savedWorkspaceSurfaceCount(self: *Self) usize {
        const priv = self.private();
        var result: usize = 0;
        const page_count = priv.tab_view.getNPages();
        for (0..@intCast(page_count)) |i| {
            const page = priv.tab_view.getNthPage(@intCast(i));
            const child = page.getChild();
            const workspace_page = gobject.ext.cast(WorkspacePage, child) orelse continue;
            result += workspacePageSurfaceCount(workspace_page);
        }
        return result;
    }

    fn syncWorkspaceListBadges(self: *Self) void {
        const priv = self.private();
        const n = priv.tab_view.getNPages();
        for (0..@intCast(n)) |i| {
            const page = priv.tab_view.getNthPage(@intCast(i));
            const child = page.getChild();
            const workspace_page = gobject.ext.cast(WorkspacePage, child) orelse continue;
            const summary = summarizeWorkspacePageAttention(workspace_page);
            if (!summary.needs_attention) {
                priv.workspace_sidebar.updateRowBadge(@intCast(i), null);
                continue;
            }

            var buf: [32:0]u8 = undefined;
            const text = if (summary.bell_count > 0)
                std.fmt.bufPrintZ(&buf, "🔔 {d}", .{summary.bell_count}) catch "🔔"
            else if (summary.unread_count > 0)
                std.fmt.bufPrintZ(&buf, "{d}", .{summary.unread_count}) catch "•"
            else
                "•";
            priv.workspace_sidebar.updateRowBadge(@intCast(i), text);
        }
    }

    fn syncWorkspaceListDescriptors(self: *Self) void {
        const priv = self.private();
        const n = priv.tab_view.getNPages();
        const alloc = Application.default().allocator();

        for (0..@intCast(n)) |i| {
            const page = priv.tab_view.getNthPage(@intCast(i));
            const child = page.getChild();
            const workspace_page = gobject.ext.cast(WorkspacePage, child) orelse continue;

            const runtime = self.getWorkspaceRuntimeForPage(workspace_page) orelse {
                priv.workspace_sidebar.updateRowDescriptor(
                    @intCast(i),
                    workspace_page.getSidebarTitle() orelse "Workspace",
                    workspace_page.getSidebarSubtitle() orelse "",
                    workspace_page.getTooltip(),
                );
                continue;
            };

            const selected = workspace_registry.selectedSessionDescriptor(runtime);
            var fallback_title_allocated = false;
            const title: [:0]const u8 = workspace_page.getSidebarTitle() orelse
                workspace_page.getTitleOverride() orelse title: {
                fallback_title_allocated = true;
                break :title alloc.dupeZ(u8, runtime.workspace.name) catch "Workspace";
            };
            defer if (fallback_title_allocated) alloc.free(title);

            var fallback_subtitle_allocated = false;
            const base_subtitle: ?[:0]const u8 = workspace_page.getSidebarSubtitle() orelse subtitle: {
                const selected_desc = selected orelse break :subtitle null;
                fallback_subtitle_allocated = true;
                const display = allocRestoreDisplayPath(alloc, selected_desc.cwd) catch {
                    fallback_subtitle_allocated = false;
                    break :subtitle null;
                };
                defer alloc.free(display);
                break :subtitle alloc.dupeZ(u8, display) catch {
                    fallback_subtitle_allocated = false;
                    break :subtitle null;
                };
            };
            defer if (fallback_subtitle_allocated and base_subtitle != null) alloc.free(base_subtitle.?);

            var subtitle_allocated = true;
            const subtitle = WorkspaceSidebar.formatSidebarSubtitle(
                alloc,
                base_subtitle,
                workspace_registry.sidebarCounts(runtime),
            ) catch blk: {
                subtitle_allocated = false;
                break :blk base_subtitle orelse "";
            };
            defer if (subtitle_allocated) alloc.free(subtitle);

            const tooltip = WorkspaceSidebar.formatSidebarTooltip(alloc, runtime) catch null;
            defer if (tooltip) |text| alloc.free(text);
            priv.workspace_sidebar.updateRowDescriptor(
                @intCast(i),
                title,
                subtitle,
                if (tooltip) |text| text else workspace_page.getTooltip(),
            );
        }
    }

    fn summarizeWorkspacePageAttention(workspace_page: *WorkspacePage) workspace_attention.AttentionSummary {
        var summary: workspace_attention.AttentionSummary = .{};
        const tree = workspace_page.getSurfaceTree() orelse return summary;

        var it = tree.iterator();
        while (it.next()) |entry| {
            const leaf = entry.view;
            const n = leaf.getSurfaceCount();
            for (0..@intCast(n)) |i| {
                const surface = leaf.getSurfaceAt(@intCast(i)) orelse continue;
                const unread = surface.getUnreadPending();
                const bell = surface.getBellRinging();
                if (unread) summary.unread_count += 1;
                if (bell) summary.bell_count += 1;
                summary.needs_attention = summary.needs_attention or unread or bell;
            }
        }

        return summary;
    }

    /// Returns true if this window needs confirmation before quitting.
    fn getNeedsConfirmQuit(self: *Self) bool {
        const priv = self.private();
        const n = priv.tab_view.getNPages();
        assert(n >= 0);

        for (0..@intCast(n)) |i| {
            const page = priv.tab_view.getNthPage(@intCast(i));
            const child = page.getChild();
            const workspace_page = gobject.ext.cast(WorkspacePage, child) orelse {
                log.warn("unexpected non-WorkspacePage child in workspace view", .{});
                continue;
            };
            if (workspace_page.getNeedsConfirmQuit()) return true;
        }

        return false;
    }

    fn isFullscreen(self: *Window) bool {
        return self.as(gtk.Window).isFullscreen() != 0;
    }

    fn isMaximized(self: *Window) bool {
        return self.as(gtk.Window).isMaximized() != 0;
    }

    fn getHeaderbarVisible(self: *Self) bool {
        const priv = self.private();

        // Never display the header bar when CSDs are disabled.
        const csd_enabled = priv.winproto.clientSideDecorationEnabled();
        if (!csd_enabled) return false;

        // Never display the header bar as a quick terminal.
        if (priv.quick_terminal) return false;

        // If we're fullscreen we never show the header bar.
        if (self.isFullscreen()) return false;

        // The remainder needs a config
        const config_obj = self.private().config orelse return true;
        const config = config_obj.get();

        // *Conditionally* disable the header bar when maximized, and
        // gtk-titlebar-hide-when-maximized is set
        if (self.isMaximized() and config.@"gtk-titlebar-hide-when-maximized") {
            return false;
        }

        return switch (config.@"gtk-titlebar-style") {
            // The top-level page selector now lives in the sidebar, so we no
            // longer hide the header bar when the user prefers tab-style chrome.
            .tabs, .native => config.@"gtk-titlebar",
        };
    }

    fn getTabsAutohide(self: *Self) bool {
        const priv = self.private();
        const config = if (priv.config) |v| v.get() else return true;

        return switch (config.@"gtk-titlebar-style") {
            // If the titlebar style is tabs we cannot autohide.
            .tabs => false,

            .native => switch (config.@"window-show-tab-bar") {
                // Auto we always autohide... obviously.
                .auto => true,

                // Always we never autohide because we always show the tab bar.
                .always => false,

                // Never we autohide because it doesn't actually matter,
                // since getTabsVisible will return false.
                .never => true,
            },
        };
    }

    fn getTabsVisible(self: *Self) bool {
        const priv = self.private();
        const config = if (priv.config) |v| v.get() else return true;

        _ = config;
        return false;
    }

    fn getTabsWide(self: *Self) bool {
        const priv = self.private();
        const config = if (priv.config) |v| v.get() else return true;
        return config.@"gtk-wide-tabs";
    }

    fn getToolbarStyle(self: *Self) adw.ToolbarStyle {
        const priv = self.private();
        const config = if (priv.config) |v| v.get() else return .raised;
        return switch (config.@"gtk-toolbar-style") {
            .flat => .flat,
            .raised => .raised,
            .@"raised-border" => .raised_border,
        };
    }

    fn getTitlebarStyle(self: *Self) TitlebarStyle {
        const priv = self.private();
        const config = if (priv.config) |v| v.get() else return .native;
        return config.@"gtk-titlebar-style";
    }

    fn propConfig(
        _: *adw.ApplicationWindow,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        const priv = self.private();
        if (priv.config) |config_obj| {
            const config = config_obj.get();
            if (config.@"app-notifications".@"config-reload") {
                self.addToast(i18n._("Reloaded the configuration"));
            }
        }

        self.syncAppearance();
    }

    fn propIsActive(
        _: *gtk.Window,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        const priv = self.private();

        // Use a timeout callback to wait for focus state to settle,
        // because depending on the windowing backend the window might
        // become inactive and immediately active again. This happens
        // e.g. on Wayland when opening a context menu or a submenu
        // inside a context menu.
        if (priv.handle_active_state_source == null) {
            priv.handle_active_state_source = glib.timeoutAddFull(
                // Use priority of an idle callback instead of the higher
                // default timeout priority. This allows us to use a shorter
                // timeout duration.
                glib.PRIORITY_DEFAULT_IDLE,
                // 50ms was chosen to be conservative. From testing we know
                // that, depending on the backend and system performance, a
                // shorter timeout or just an idle callback can be enough for
                // the focus to settle. On the other hand a delay of e.g. 10ms
                // does not work reliably on some slow systems. The downside
                // of a high value is that some operations in handleActiveState,
                // e.g. hiding the quick-terminal, will be visibly delayed.
                // However, 50ms should barely be noticeable. We can change
                // this in the future if necessary.
                50,
                handleActiveState,
                self,
                null,
            );
        }
    }

    fn propGdkSurfaceDims(
        _: *gdk.Surface,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        // X11 needs to fix blurring on resize, but winproto implementations
        // could do anything.
        self.private().winproto.resizeEvent() catch |err| {
            log.warn(
                "winproto resize event failed error={}",
                .{err},
            );
        };
    }

    fn toplevelComputeSize(
        _: *gdk.Toplevel,
        size: *gdk.ToplevelSize,
        self: *Self,
    ) callconv(.c) void {
        // The compositor/quick terminal own the size in these states.
        if (self.isMaximized() or
            self.isFullscreen() or
            self.isQuickTerminal()) return;

        // If there's no GdkSurface yet these dimensions will be zero size which
        // will make the window start out as small as possible. These checks ensure
        // we don't start with a 0, 0 window size.
        const gdk_surface = self.as(gtk.Native).getSurface() orelse return;
        const w = gdk_surface.getWidth();
        const h = gdk_surface.getHeight();
        if (w <= 0 or h <= 0) return;

        // GTK clamps the requested size to the compositor-reported bounds, which
        // go stale when the window moves to a larger monitor. Only re-assert the
        // current size when it exceeds those bounds; otherwise let GTK's default
        // sizing win so a freshly-mapped window isn't forced to a tiny size.
        var bounds_w: c_int = undefined;
        var bounds_h: c_int = undefined;
        size.getBounds(&bounds_w, &bounds_h);

        if (bounds_w <= 0 or bounds_h <= 0) return;
        if (w <= bounds_w and h <= bounds_h) return;

        size.setSize(w, h);
    }

    fn propFullscreened(
        _: *adw.ApplicationWindow,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        self.syncAppearance();
    }

    fn propMaximized(
        _: *adw.ApplicationWindow,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        self.syncAppearance();
    }

    fn propMenuActive(
        button: *gtk.MenuButton,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        // Debian 12 is stuck on GTK 4.8
        if (!gtk_version.atLeast(4, 10, 0)) return;

        // We only care if we're activating. If we're activating then
        // we need to check the validity of our menu items.
        const active = button.getActive() != 0;
        if (!active) return;

        self.syncActions();
    }

    fn propQuickTerminal(
        _: *adw.ApplicationWindow,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        const priv = self.private();
        if (priv.surface_init) {
            log.warn("quick terminal property can't be changed after surfaces have been initialized", .{});
            return;
        }

        if (priv.quick_terminal) {
            // Initialize the quick terminal at the app-layer
            Application.default().winproto().initQuickTerminal(self) catch |err| {
                log.warn("failed to initialize quick terminal error={}", .{err});
                return;
            };
        }
    }

    fn propScaleFactor(
        _: *adw.ApplicationWindow,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        // On some platforms (namely X11) we need to refresh our appearance when
        // the scale factor changes. In theory this could be more fine-grained as
        // a full refresh could be expensive, but a) this *should* be rare, and
        // b) quite noticeable visual bugs would occur if this is not present.
        self.private().winproto.syncAppearance() catch |err| {
            log.warn(
                "failed to sync appearance after scale factor has been updated={}",
                .{err},
            );
            return;
        };
    }

    fn closureTitlebarStyleIsTab(
        _: *Self,
        value: TitlebarStyle,
    ) callconv(.c) c_int {
        return @intFromBool(switch (value) {
            .native => false,
            .tabs => true,
        });
    }

    fn closureSubtitle(
        _: *Self,
        config_: ?*Config,
        pwd_: ?[*:0]const u8,
    ) callconv(.c) ?[*:0]const u8 {
        const config = if (config_) |v| v.get() else return null;
        return switch (config.@"window-subtitle") {
            .false => null,
            .@"working-directory" => pwd: {
                const pwd = pwd_ orelse return null;
                break :pwd glib.ext.dupeZ(u8, std.mem.span(pwd));
            },
        };
    }

    //---------------------------------------------------------------
    // Virtual methods

    fn dispose(self: *Self) callconv(.c) void {
        const priv = self.private();
        self.autosaveAllWorkspacesOnShutdown();
        priv.disposing_runtime = true;

        if (priv.handle_active_state_source) |v| {
            if (glib.Source.remove(v) == 0) {
                log.warn("unable to remove handle active state source", .{});
            }
            priv.handle_active_state_source = null;
        }

        priv.command_palette.set(null);

        if (priv.config) |v| {
            v.unref();
            priv.config = null;
        }

        priv.workspace_page_bindings.setSource(null);
        priv.context_menu_page = null;
        if (priv.pending_surface_focus_source) |source| {
            _ = glib.Source.remove(source);
            priv.pending_surface_focus_source = null;
        }
        if (priv.pending_workspace_autosave_source) |source| {
            _ = glib.Source.remove(source);
            priv.pending_workspace_autosave_source = null;
        }
        if (priv.pending_workspace_autosave_page) |workspace_page| {
            workspace_page.unref();
            priv.pending_workspace_autosave_page = null;
        }
        if (priv.periodic_workspace_autosave_source) |source| {
            _ = glib.Source.remove(source);
            priv.periodic_workspace_autosave_source = null;
        }
        const page_count = priv.tab_view.getNPages();
        for (0..@intCast(page_count)) |i| {
            const page = priv.tab_view.getNthPage(@intCast(i));
            const child = page.getChild();
            const workspace_page = gobject.ext.cast(WorkspacePage, child) orelse continue;
            _ = gobject.signalHandlersDisconnectMatched(
                workspace_page.as(gobject.Object),
                .{ .data = true },
                0,
                0,
                null,
                null,
                self,
            );
            if (workspace_page.getSurfaceTree()) |tree| {
                self.disconnectSurfaceHandlers(tree);
            }
        }
        gtk.Widget.disposeTemplate(
            self.as(gtk.Widget),
            getGObjectType(),
        );

        priv.session_identity_index.deinit();
        deinitSavedScrollbackStates(self);
        priv.scrollback_saved_states.deinit();
        priv.workspace_ids_by_page.deinit();
        priv.split_ids_by_leaf.deinit();
        priv.tab_ids_by_widget.deinit();
        priv.surface_ids_by_widget.deinit();
        priv.runtime_registry.deinit();

        gobject.Object.virtual_methods.dispose.call(
            Class.parent,
            self.as(Parent),
        );
    }

    fn finalize(self: *Self) callconv(.c) void {
        const priv = self.private();
        priv.workspace_page_bindings.unref();
        priv.winproto.deinit();

        gobject.Object.virtual_methods.finalize.call(
            Class.parent,
            self.as(Parent),
        );
    }

    //---------------------------------------------------------------
    // Signal handlers

    fn windowRealize(_: *gtk.Widget, self: *Window) callconv(.c) void {
        const app = Application.default();

        // Initialize our window protocol logic
        if (winprotopkg.Window.init(
            app.allocator(),
            app.winproto(),
            self,
        )) |wp| {
            self.private().winproto = wp;
        } else |err| {
            log.warn("failed to initialize window protocol error={}", .{err});
            return;
        }

        // We need to setup resize notifications on our surface,
        // which is only available after the window had been realized.
        if (self.as(gtk.Native).getSurface()) |gdk_surface| {
            _ = gobject.Object.signals.notify.connect(
                gdk_surface,
                *Self,
                propGdkSurfaceDims,
                self,
                .{ .detail = "width" },
            );
            _ = gobject.Object.signals.notify.connect(
                gdk_surface,
                *Self,
                propGdkSurfaceDims,
                self,
                .{ .detail = "height" },
            );
            // Connect after GTK's compute-size handler so our size wins.
            if (gobject.ext.cast(gdk.Toplevel, gdk_surface)) |toplevel| {
                _ = gdk.Toplevel.signals.compute_size.connect(
                    toplevel,
                    *Self,
                    toplevelComputeSize,
                    self,
                    .{ .after = true },
                );
            }
        }

        // When we are realized we always setup our appearance since this
        // calls some winproto functions.
        self.syncAppearance();
    }

    fn btnNewTab(_: *adw.SplitButton, self: *Self) callconv(.c) void {
        self.performBindingAction(.new_tab);
    }

    fn btnNewWorkspace(_: *gtk.Button, self: *Self) callconv(.c) void {
        self.newWorkspace(if (self.getActiveSurface()) |v| v.core() else null);
    }

    fn btnToggleSidebar(_: *gtk.Button, self: *Self) callconv(.c) void {
        self.toggleWorkspaceSidebar();
    }

    fn tabOverviewCreateTab(
        _: *adw.TabOverview,
        self: *Self,
    ) callconv(.c) *adw.TabPage {
        return self.newWorkspacePage(if (self.getActiveSurface()) |v| v.core() else null, .tab, .none);
    }

    fn tabOverviewOpen(
        tab_overview: *adw.TabOverview,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        // We only care about when the tab overview is closed.
        if (tab_overview.getOpen() != 0) return;

        // On tab overview close, focus is sometimes lost. This is an
        // upstream issue in libadwaita[1]. When this is resolved we
        // can put a runtime version check here to avoid this workaround.
        //
        // Our workaround is to start a timer after 500ms to refocus
        // the currently selected workspace page. We choose 500ms because the adw
        // animation is 400ms.
        //
        // [1]: https://gitlab.gnome.org/GNOME/libadwaita/-/issues/670

        // If we have an old timer remove it
        const priv = self.private();
        if (priv.tab_overview_focus_timer) |timer| {
            _ = glib.Source.remove(timer);
        }

        // Restart our timer
        priv.tab_overview_focus_timer = glib.timeoutAdd(
            500,
            tabOverviewFocusTimer,
            self,
        );
    }

    fn tabOverviewFocusTimer(
        ud: ?*anyopaque,
    ) callconv(.c) c_int {
        const self: *Self = @ptrCast(@alignCast(ud orelse return 0));

        // Always note our timer is removed
        self.private().tab_overview_focus_timer = null;

        // Get our currently active surface which should respect the newly
        // selected workspace page. Grab focus.
        const surface = self.getActiveSurface() orelse return 0;
        surface.grabFocus();

        // Remove the timer
        return 0;
    }

    fn windowCloseRequest(
        _: *gtk.Window,
        self: *Self,
    ) callconv(.c) c_int {
        if (self.getNeedsConfirmQuit()) {
            // Show a confirmation dialog
            const dialog: *CloseConfirmationDialog = .new(.window);
            _ = CloseConfirmationDialog.signals.@"close-request".connect(
                dialog,
                *Self,
                closeConfirmationClose,
                self,
                .{},
            );

            // Show it
            dialog.present(self.as(gtk.Widget));
            return @intFromBool(true);
        }

        self.as(gtk.Window).destroy();
        return @intFromBool(false);
    }

    fn closeConfirmationClose(
        _: *CloseConfirmationDialog,
        self: *Self,
    ) callconv(.c) void {
        self.as(gtk.Window).destroy();
    }

    fn closeConfirmationCloseTab(
        _: *CloseConfirmationDialog,
        page: *adw.TabPage,
    ) callconv(.c) void {
        const tab_view = ext.getAncestor(
            adw.TabView,
            page.getChild().as(gtk.Widget),
        ) orelse {
            log.warn("close confirmation called for non-existent page", .{});
            return;
        };
        tab_view.closePageFinish(page, @intFromBool(true));
    }

    fn closeConfirmationCancelTab(
        _: *CloseConfirmationDialog,
        page: *adw.TabPage,
    ) callconv(.c) void {
        const tab_view = ext.getAncestor(
            adw.TabView,
            page.getChild().as(gtk.Widget),
        ) orelse {
            log.warn("close confirmation called for non-existent page", .{});
            return;
        };
        tab_view.closePageFinish(page, @intFromBool(false));
    }

    fn tabViewClosePage(
        _: *adw.TabView,
        page: *adw.TabPage,
        self: *Self,
    ) callconv(.c) c_int {
        const priv = self.private();
        const child = page.getChild();
        const workspace_page = gobject.ext.cast(WorkspacePage, child) orelse
            return @intFromBool(false);

        // If the workspace page says it doesn't need confirmation then we go ahead
        // and close immediately.
        if (!workspace_page.getNeedsConfirmQuit()) {
            priv.tab_view.closePageFinish(page, @intFromBool(true));
            return @intFromBool(true);
        }

        // Show a confirmation dialog
        const dialog: *CloseConfirmationDialog = .new(.workspace);
        _ = CloseConfirmationDialog.signals.@"close-request".connect(
            dialog,
            *adw.TabPage,
            closeConfirmationCloseTab,
            page,
            .{},
        );
        _ = CloseConfirmationDialog.signals.cancel.connect(
            dialog,
            *adw.TabPage,
            closeConfirmationCancelTab,
            page,
            .{},
        );

        // Show it
        dialog.present(child);
        return @intFromBool(true);
    }

    fn tabViewSelectedPage(
        _: *adw.TabView,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        const priv = self.private();

        // Always reset our binding source in case we have no pages.
        priv.workspace_page_bindings.setSource(null);

        // Get our current page which MUST be a WorkspacePage object.
        const page = priv.tab_view.getSelectedPage() orelse return;
        const child = page.getChild();
        assert(gobject.ext.isA(child, WorkspacePage));

        // Setup our binding group. This ensures things like the title
        // are synced from the active workspace page.
        priv.workspace_page_bindings.setSource(child.as(gobject.Object));
        self.syncWorkspaceSidebarSelection();

        // If the tab was previously marked as needing attention
        // (e.g. due to a bell character), we now unmark that
        page.setNeedsAttention(@intFromBool(false));
        self.refreshWorkspaceRegistrySafe();
    }

    fn tabViewPageAttached(
        _: *adw.TabView,
        page: *adw.TabPage,
        _: c_int,
        self: *Self,
    ) callconv(.c) void {
        // Get the attached page which must be a WorkspacePage object.
        const child = page.getChild();
        const workspace_page = gobject.ext.cast(WorkspacePage, child) orelse return;

        // Attach listeners for the workspace page.
        _ = WorkspacePage.signals.@"close-request".connect(
            workspace_page,
            *Self,
            workspacePageCloseRequest,
            self,
            .{},
        );

        // Attach listeners for the surface.
        //
        // Interesting behavior here that was previously undocumented but
        // I'm going to make it explicit here: we accept all the signals here
        // (like toggle-fullscreen) regardless of whether the surface or tab
        // is focused. At the time of writing this we have no API that could
        // really trigger these that way but its theoretically possible.
        //
        // What is DEFINITELY possible is something like OSC52 triggering
        // a clipboard-write signal on an unfocused tab/surface. We definitely
        // want to show the user a notification about that but our notification
        // right now is a toast that doesn't make it clear WHO used the
        // clipboard. We probably want to change that in the future.
        //
        // I'm not sure how desirable all the above is, and we probably
        // should be thoughtful about future signals here. But all of this
        // behavior is consistent with macOS and the previous GTK apprt,
        // but that behavior was all implicit and not documented, so here
        // I am.
        if (workspace_page.getSurfaceTree()) |tree| {
            self.connectSurfaceHandlers(tree);
        }
        _ = gobject.Object.signals.notify.connect(
            workspace_page.as(gobject.Object),
            *Self,
            workspacePageRuntimeStateChanged,
            self,
            .{ .detail = "active-surface" },
        );
        _ = gobject.Object.signals.notify.connect(
            workspace_page.as(gobject.Object),
            *Self,
            workspacePageRestorableStateChanged,
            self,
            .{ .detail = "title-override" },
        );
        _ = gobject.Object.signals.notify.connect(
            workspace_page.as(gobject.Object),
            *Self,
            workspacePageRestorableStateChanged,
            self,
            .{ .detail = "sidebar-title" },
        );
        _ = gobject.Object.signals.notify.connect(
            workspace_page.as(gobject.Object),
            *Self,
            workspacePageRestorableStateChanged,
            self,
            .{ .detail = "sidebar-subtitle" },
        );
        self.refreshWorkspaceRegistrySafe();
    }

    fn tabViewPageDetached(
        _: *adw.TabView,
        page: *adw.TabPage,
        _: c_int,
        self: *Self,
    ) callconv(.c) void {
        if (self.private().disposing_runtime) return;

        // We need to get the workspace page to disconnect the signals.
        const child = page.getChild();
        const workspace_page = gobject.ext.cast(WorkspacePage, child) orelse return;
        _ = gobject.signalHandlersDisconnectMatched(
            workspace_page.as(gobject.Object),
            .{ .data = true },
            0,
            0,
            null,
            null,
            self,
        );

        // Remove the tree handlers
        if (workspace_page.getSurfaceTree()) |tree| {
            self.disconnectSurfaceHandlers(tree);
        }

        const priv = self.private();
        const page_key = ptrKey(workspace_page);
        if (priv.workspace_ids_by_page.get(page_key)) |workspace_id| {
            _ = priv.runtime_registry.removeWorkspace(workspace_id);
            _ = priv.workspace_ids_by_page.remove(page_key);
        }
        self.refreshWorkspaceRegistrySafe();
    }

    fn tabViewCreateWindow(
        _: *adw.TabView,
        _: *Self,
    ) callconv(.c) *adw.TabView {
        // Create a new window without creating a new tab.
        const win = gobject.ext.newInstance(
            Self,
            .{
                .application = Application.default(),
            },
        );

        // We have to show it otherwise it'll just be hidden.
        gtk.Window.present(win.as(gtk.Window));

        // Get our tab view
        return win.private().tab_view;
    }

    fn workspacePageCloseRequest(
        workspace_page: *WorkspacePage,
        self: *Self,
    ) callconv(.c) void {
        const priv = self.private();
        const page = priv.tab_view.getPage(workspace_page.as(gtk.Widget));
        // TODO: connect close page handler to tab to check for confirmation
        priv.tab_view.closePage(page);
    }

    fn tabViewNPages(
        _: *adw.TabView,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        const priv = self.private();
        if (priv.tab_view.getNPages() == 0) {
            // If we have no pages left then we want to close window.

            // If the tab overview is open, then we don't close the window
            // because its a rather abrupt experience. This also fixes an
            // issue where dragging out the last tab in the tab overview
            // won't cause Ghostty to exit.
            if (priv.tab_overview.getOpen() != 0) return;

            self.as(gtk.Window).close();
        }
    }
    fn setupTabMenu(
        _: *adw.TabView,
        page: ?*adw.TabPage,
        self: *Self,
    ) callconv(.c) void {
        self.private().context_menu_page = page;
    }

    fn surfaceClipboardWrite(
        _: *Surface,
        clipboard_type: apprt.Clipboard,
        text: [*:0]const u8,
        self: *Self,
    ) callconv(.c) void {
        // We only toast for the standard clipboard.
        if (clipboard_type != .standard) return;

        // We only toast if configured to
        const priv = self.private();
        const config_obj = priv.config orelse return;
        const config = config_obj.get();
        if (!config.@"app-notifications".@"clipboard-copy") {
            return;
        }

        if (text[0] != 0)
            self.addToast(i18n._("Copied to clipboard"))
        else
            self.addToast(i18n._("Cleared clipboard"));
    }

    fn surfaceMenu(
        _: *Surface,
        self: *Self,
    ) callconv(.c) void {
        self.syncActions();
    }

    fn surfacePresentRequest(
        surface: *Surface,
        self: *Self,
    ) callconv(.c) void {
        // Verify that this surface is actually in this window.
        {
            const surface_window = ext.getAncestor(
                Self,
                surface.as(gtk.Widget),
            ) orelse {
                log.warn(
                    "present request called for non-existent surface",
                    .{},
                );
                return;
            };
            if (surface_window != self) {
                log.warn(
                    "present request called for surface in different window",
                    .{},
                );
                return;
            }
        }

        // Get the tab for this surface.
        const workspace_page = ext.getAncestor(
            WorkspacePage,
            surface.as(gtk.Widget),
        ) orelse {
            log.warn("present request surface not found", .{});
            return;
        };

        // Get the page that contains this workspace page.
        const priv = self.private();
        const tab_view = priv.tab_view;
        const page = tab_view.getPage(workspace_page.as(gtk.Widget));
        tab_view.setSelectedPage(page);

        // Grab focus
        surface.grabFocus();

        // Bring the window to the front.
        self.as(gtk.Window).present();
    }

    fn surfaceToggleFullscreen(
        surface: *Surface,
        self: *Self,
    ) callconv(.c) void {
        _ = surface;
        if (self.as(gtk.Window).isFullscreen() != 0) {
            self.as(gtk.Window).unfullscreen();
        } else {
            self.as(gtk.Window).fullscreen();
        }

        // We react to the changes in the propFullscreen callback
    }

    fn surfaceToggleMaximize(
        surface: *Surface,
        self: *Self,
    ) callconv(.c) void {
        _ = surface;
        if (self.as(gtk.Window).isMaximized() != 0) {
            self.as(gtk.Window).unmaximize();
        } else {
            self.as(gtk.Window).maximize();
        }

        // We react to the changes in the propMaximized callback
    }

    fn surfaceInit(
        surface: *Surface,
        self: *Self,
    ) callconv(.c) void {
        const priv = self.private();

        // Make sure we init only once
        if (priv.surface_init) return;
        priv.surface_init = true;

        // Setup our default and minimum size.
        if (surface.getDefaultSize()) |size| {
            self.as(gtk.Window).setDefaultSize(
                @intCast(size.width),
                @intCast(size.height),
            );
        }
        if (surface.getMinSize()) |size| {
            self.as(gtk.Widget).setSizeRequest(
                @intCast(size.width),
                @intCast(size.height),
            );
        }
    }

    fn workspacePageSplitTreeChanged(
        split_tree: *SplitTree,
        old_tree: ?*const SplitTabs.Tree,
        new_tree: ?*const SplitTabs.Tree,
        self: *Self,
    ) callconv(.c) void {
        if (old_tree) |tree| {
            self.disconnectSurfaceHandlers(tree);
        }

        if (new_tree) |tree| {
            self.connectSurfaceHandlers(tree);
        }
        self.refreshWorkspaceRegistrySafe();
        self.scheduleWorkspaceAutosaveForWidget(split_tree.as(gtk.Widget));
    }

    fn workspacePageSurfaceAdded(
        _: *SplitTree,
        surface: *Surface,
        self: *Self,
    ) callconv(.c) void {
        self.connectSurfaceHandler(surface);
        self.refreshWorkspaceRegistrySafe();
        self.scheduleWorkspaceAutosaveForWidget(surface.as(gtk.Widget));
    }

    fn workspacePageSurfaceRemoved(
        _: *SplitTree,
        surface: *Surface,
        self: *Self,
    ) callconv(.c) void {
        if (self.private().session_identity_index.sessionForAttachment(@intFromPtr(surface))) |session_id| {
            removeSavedScrollbackState(self, session_id);
        }
        if (ext.getAncestor(Tab, surface.as(gtk.Widget))) |tab| {
            _ = gobject.signalHandlersDisconnectMatched(
                tab.as(gobject.Object),
                .{ .data = true },
                0,
                0,
                null,
                null,
                self,
            );
        }
        _ = gobject.signalHandlersDisconnectMatched(
            surface.as(gobject.Object),
            .{ .data = true },
            0,
            0,
            null,
            null,
            self,
        );
        self.refreshWorkspaceRegistrySafe();
        self.scheduleWorkspaceAutosaveForWidget(surface.as(gtk.Widget));
    }

    fn workspacePageRuntimeStateChanged(
        _: *gobject.Object,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        self.refreshWorkspaceRegistrySafe();
    }

    fn workspacePageRestorableStateChanged(
        object: *gobject.Object,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        self.refreshWorkspaceRegistrySafe();
        const workspace_page = gobject.ext.cast(WorkspacePage, object) orelse return;
        self.scheduleWorkspaceAutosaveForPage(workspace_page);
    }

    fn surfaceRuntimeStateChanged(
        _: *gobject.Object,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        self.refreshWorkspaceRegistrySafe();
    }

    fn surfaceRestorableStateChanged(
        object: *gobject.Object,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        self.refreshWorkspaceRegistrySafe();
        const surface = gobject.ext.cast(Surface, object) orelse return;
        self.scheduleWorkspaceAutosaveForWidget(surface.as(gtk.Widget));
    }

    fn tabRestorableStateChanged(
        object: *gobject.Object,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        self.refreshWorkspaceRegistrySafe();
        const tab = gobject.ext.cast(Tab, object) orelse return;
        self.scheduleWorkspaceAutosaveForWidget(tab.as(gtk.Widget));
    }

    fn actionAbout(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Self,
    ) callconv(.c) void {
        const name = "Ghostty";
        const icon = "com.mitchellh.ghostty";
        const website = "https://ghostty.org";

        if (adw_version.supportsDialogs()) {
            adw.showAboutDialog(
                self.as(gtk.Widget),
                "application-name",
                name,
                "developer-name",
                i18n._("Ghostty Developers"),
                "application-icon",
                icon,
                "version",
                build_config.version_string.ptr,
                "issue-url",
                "https://github.com/ghostty-org/ghostty/issues",
                "website",
                website,
                @as(?*anyopaque, null),
            );
        } else {
            gtk.showAboutDialog(
                self.as(gtk.Window),
                "program-name",
                name,
                "logo-icon-name",
                icon,
                "title",
                i18n._("About Ghostty"),
                "version",
                build_config.version_string.ptr,
                "website",
                website,
                @as(?*anyopaque, null),
            );
        }
    }

    fn actionClose(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Self,
    ) callconv(.c) void {
        self.as(gtk.Window).close();
    }

    fn actionCloseTab(
        _: *gio.SimpleAction,
        param_: ?*glib.Variant,
        self: *Window,
    ) callconv(.c) void {
        const param = param_ orelse {
            log.warn("win.close-tab called without a parameter", .{});
            return;
        };

        var str: ?[*:0]const u8 = null;
        param.get("&s", &str);

        const mode = std.meta.stringToEnum(
            input.Binding.Action.CloseTabMode,
            std.mem.span(
                str orelse {
                    log.warn("invalid mode provided to win.close-tab", .{});
                    return;
                },
            ),
        ) orelse {
            log.warn("invalid mode provided to win.close-tab: {s}", .{str.?});
            return;
        };

        self.performBindingAction(.{ .close_tab = mode });
    }

    fn actionNewWindow(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Window,
    ) callconv(.c) void {
        self.performBindingAction(.new_window);
    }

    fn actionNewTab(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Window,
    ) callconv(.c) void {
        self.performBindingAction(.new_tab);
    }

    fn idleWorkspacePageAction(ud: ?*anyopaque) callconv(.c) c_int {
        const ctx: *WorkspacePageIdleContext = @ptrCast(@alignCast(ud orelse return 0));
        defer ctx.deinit();

        switch (ctx.action) {
            .prompt_title => {
                ctx.workspace_page.promptWorkspaceTitle();
            },
            .save => {
                const window = ext.getAncestor(Self, ctx.workspace_page.as(gtk.Widget)) orelse return 0;
                window.saveWorkspacePage(ctx.workspace_page);
            },
            .reveal_snapshot => {
                const window = ext.getAncestor(Self, ctx.workspace_page.as(gtk.Widget)) orelse return 0;
                window.revealWorkspaceSnapshot(ctx.workspace_page);
            },
            .open_snapshot => {
                const window = ext.getAncestor(Self, ctx.workspace_page.as(gtk.Widget)) orelse return 0;
                window.openWorkspaceSnapshot(ctx.workspace_page);
            },
            .delete_snapshot => {
                const window = ext.getAncestor(Self, ctx.workspace_page.as(gtk.Widget)) orelse return 0;
                window.deleteWorkspaceSnapshot(ctx.workspace_page);
            },
            .close => {
                const window = ext.getAncestor(Self, ctx.workspace_page.as(gtk.Widget)) orelse return 0;
                window.closeWorkspacePage(ctx.workspace_page);
            },
        }
        return 0;
    }

    const WorkspacePageIdleContext = struct {
        workspace_page: *WorkspacePage,
        action: WorkspacePageIdleAction,

        fn new(workspace_page: *WorkspacePage, action: WorkspacePageIdleAction) *WorkspacePageIdleContext {
            const ctx = std.heap.c_allocator.create(WorkspacePageIdleContext) catch @panic("oom");
            ctx.* = .{
                .workspace_page = workspace_page.ref(),
                .action = action,
            };
            return ctx;
        }

        fn deinit(self: *WorkspacePageIdleContext) void {
            self.workspace_page.unref();
            std.heap.c_allocator.destroy(self);
        }
    };

    fn queueWorkspacePageIdleAction(workspace_page: *WorkspacePage, action: WorkspacePageIdleAction) void {
        _ = glib.idleAdd(idleWorkspacePageAction, WorkspacePageIdleContext.new(workspace_page, action));
    }

    fn getContextMenuWorkspacePage(self: *Self) ?*WorkspacePage {
        const priv = self.private();
        const page = priv.context_menu_page orelse return null;
        return gobject.ext.cast(WorkspacePage, page.getChild());
    }

    fn idleShowRestoreWorkspaceCommands(ud: ?*anyopaque) callconv(.c) c_int {
        const self: *Self = @ptrCast(@alignCast(ud orelse return 0));
        defer self.unref();
        self.showRestoreWorkspaceCommands();
        return 0;
    }

    fn promptContextWorkspaceTitle(self: *Self) void {
        const workspace_page = self.getContextMenuWorkspacePage() orelse return;
        queueWorkspacePageIdleAction(workspace_page, .prompt_title);
    }

    fn saveContextWorkspace(self: *Self) void {
        const workspace_page = self.getContextMenuWorkspacePage() orelse return;
        queueWorkspacePageIdleAction(workspace_page, .save);
    }

    fn closeContextWorkspace(self: *Self) void {
        const workspace_page = self.getContextMenuWorkspacePage() orelse return;
        queueWorkspacePageIdleAction(workspace_page, .close);
    }

    fn revealContextWorkspaceSnapshot(self: *Self) void {
        const workspace_page = self.getContextMenuWorkspacePage() orelse return;
        queueWorkspacePageIdleAction(workspace_page, .reveal_snapshot);
    }

    fn openContextWorkspaceSnapshot(self: *Self) void {
        const workspace_page = self.getContextMenuWorkspacePage() orelse return;
        queueWorkspacePageIdleAction(workspace_page, .open_snapshot);
    }

    fn getOrCreateCommandPalette(self: *Window) *CommandPalette {
        const priv = self.private();
        return priv.command_palette.get() orelse command_palette: {
            const command_palette = CommandPalette.new();

            _ = gobject.Object.bindProperty(
                self.as(gobject.Object),
                "config",
                command_palette.as(gobject.Object),
                "config",
                .{ .sync_create = true },
            );

            _ = CommandPalette.signals.trigger.connect(
                command_palette,
                *Window,
                signalCommandPaletteTrigger,
                self,
                .{},
            );

            priv.command_palette.set(command_palette);
            break :command_palette command_palette;
        };
    }

    fn actionPromptContextWorkspaceTitle(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Self,
    ) callconv(.c) void {
        self.promptContextWorkspaceTitle();
    }

    fn actionSaveContextWorkspace(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Self,
    ) callconv(.c) void {
        self.saveContextWorkspace();
    }

    fn actionCloseContextWorkspace(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Self,
    ) callconv(.c) void {
        self.closeContextWorkspace();
    }

    fn actionRevealContextWorkspaceSnapshot(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Self,
    ) callconv(.c) void {
        self.revealContextWorkspaceSnapshot();
    }

    fn actionOpenContextWorkspaceSnapshot(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Self,
    ) callconv(.c) void {
        self.openContextWorkspaceSnapshot();
    }

    fn actionPromptWorkspaceTitle(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Window,
    ) callconv(.c) void {
        const workspace_page = self.getSelectedWorkspacePage() orelse return;
        queueWorkspacePageIdleAction(workspace_page, .prompt_title);
    }

    fn actionPromptSurfaceTitle(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Window,
    ) callconv(.c) void {
        self.performBindingAction(.prompt_surface_title);
    }

    fn actionPromptTabTitle(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Window,
    ) callconv(.c) void {
        self.performBindingAction(.prompt_tab_title);
    }

    fn saveWorkspacePage(self: *Self, workspace_page: *WorkspacePage) void {
        const alloc = Application.default().allocator();
        const result = saveWorkspaceAlloc(self, alloc, workspace_page) catch |err| {
            log.warn("failed to save workspace error={}", .{err});
            self.addToast(i18n._("Failed to save workspace"));
            return;
        };
        defer result.deinit(alloc);
        const title = std.fmt.allocPrintSentinel(alloc, "{s}: {s}", .{
            i18n._("Workspace saved"),
            std.fs.path.basename(result.path),
        }, 0) catch {
            self.addToast(i18n._("Workspace saved"));
            return;
        };
        defer alloc.free(title);
        self.addToast(title);
    }

    fn closeWorkspacePage(self: *Self, workspace_page: *WorkspacePage) void {
        const page = self.private().tab_view.getPage(workspace_page.as(gtk.Widget));
        self.private().tab_view.closePage(page);
    }

    fn revealWorkspaceSnapshot(self: *Self, workspace_page: *WorkspacePage) void {
        const alloc = Application.default().allocator();
        const snapshot_path = workspaceSnapshotPathAlloc(self, alloc, workspace_page) catch |err| {
            log.warn("failed to resolve workspace snapshot path error={}", .{err});
            self.addToast(i18n._("Failed to reveal workspace snapshot"));
            return;
        } orelse {
            self.addToast(i18n._("Save the workspace before revealing its snapshot"));
            return;
        };
        defer alloc.free(snapshot_path);

        _ = revealPathInFileManager(snapshot_path) catch |err| {
            log.warn("failed to reveal workspace snapshot error={}", .{err});
            self.addToast(i18n._("Failed to reveal workspace snapshot"));
            return;
        };
    }

    fn openWorkspaceSnapshot(self: *Self, workspace_page: *WorkspacePage) void {
        const alloc = Application.default().allocator();
        const snapshot_path = workspaceSnapshotPathAlloc(self, alloc, workspace_page) catch |err| {
            log.warn("failed to resolve workspace snapshot path error={}", .{err});
            self.addToast(i18n._("Failed to open workspace snapshot"));
            return;
        } orelse {
            self.addToast(i18n._("Save the workspace before opening its snapshot"));
            return;
        };
        defer alloc.free(snapshot_path);

        internal_os.open(alloc, .text, snapshot_path) catch |err| {
            log.warn("failed to open workspace snapshot error={}", .{err});
            self.addToast(i18n._("Failed to open workspace snapshot"));
            return;
        };
    }

    fn deleteWorkspaceSnapshot(self: *Self, workspace_page: *WorkspacePage) void {
        self.refreshWorkspaceRegistrySafe();
        const alloc = Application.default().allocator();
        const runtime = self.getWorkspaceRuntimeForPage(workspace_page) orelse {
            self.addToast(i18n._("Failed to delete saved workspace"));
            return;
        };
        var catalog = workspace_storage.readDefaultCatalogAlloc(alloc) catch |err| {
            log.warn("failed to read workspace catalog for delete error={}", .{err});
            self.addToast(i18n._("Failed to delete saved workspace"));
            return;
        };
        defer catalog.deinit(alloc);

        const entry = findSavedWorkspaceCatalogEntryForRuntime(catalog.entries, runtime) orelse {
            self.addToast(i18n._("This workspace has no saved snapshot to delete"));
            return;
        };

        var dir = workspace_storage.createDefaultStorageDirAlloc(alloc) catch |err| {
            log.warn("failed to open workspace storage directory error={}", .{err});
            self.addToast(i18n._("Failed to delete saved workspace"));
            return;
        };
        defer dir.close();

        const storage = workspace_storage.Storage.init(alloc, dir);
        if (entry.workspace_key) |workspace_key| {
            storage.pruneCheckpoint(workspace_key) catch |err| {
                log.warn("failed to delete workspace checkpoint error={}", .{err});
                self.addToast(i18n._("Failed to delete saved workspace"));
                return;
            };
        } else storage.pruneCheckpointPath(entry.path) catch |err| {
            log.warn("failed to delete workspace checkpoint error={}", .{err});
            self.addToast(i18n._("Failed to delete saved workspace"));
            return;
        };

        clearWorkspaceSnapshotRefAlloc(alloc, runtime);
        self.refreshWorkspaceRegistrySafe();
        self.addToast(i18n._("Saved workspace deleted"));
    }

    pub fn showRestoreWorkspaceCommands(self: *Window) void {
        const alloc = Application.default().allocator();
        var catalog = workspace_storage.readDefaultCatalogAlloc(alloc) catch |err| {
            log.warn("failed to read restore workspace catalog error={}", .{err});
            self.addToast(i18n._("Failed to load saved workspaces"));
            return;
        };
        defer catalog.deinit(alloc);

        if (catalog.entries.len == 0) {
            self.addToast(i18n._("No saved workspaces to restore"));
            return;
        }

        const command_palette = self.getOrCreateCommandPalette();
        defer command_palette.unref();
        command_palette.presentQuery(self, "Restore Workspace");
    }

    pub fn restoreSavedWorkspace(self: *Window, target: []const u8) void {
        self.refreshWorkspaceRegistrySafe();
        const alloc = Application.default().allocator();
        var catalog = workspace_storage.readDefaultCatalogAlloc(alloc) catch |err| {
            log.warn("failed to read restore workspace catalog error={}", .{err});
            self.addToast(i18n._("Failed to load saved workspaces"));
            return;
        };
        defer catalog.deinit(alloc);

        const entry = findSavedWorkspaceCatalogEntry(catalog.entries, target) orelse {
            self.addToast(i18n._("Saved workspace snapshot not found"));
            return;
        };

        var dir = workspace_storage.openDefaultStorageDirAlloc(alloc) catch |err| {
            log.warn("failed to open workspace storage directory error={}", .{err});
            self.addToast(i18n._("Failed to restore workspace"));
            return;
        } orelse {
            self.addToast(i18n._("No saved workspaces to restore"));
            return;
        };
        defer dir.close();

        const storage = workspace_storage.Storage.init(alloc, dir);
        var snapshot_value = storage.readSnapshotAlloc(alloc, entry.path) catch |err| {
            log.warn("failed to load workspace snapshot error={}", .{err});
            self.addToast(i18n._("Failed to restore workspace"));
            return;
        };
        defer snapshot_value.deinit(alloc);

        var plan = workspace_restore.planAlloc(alloc, snapshot_value) catch |err| {
            log.warn("failed to plan workspace restore error={}", .{err});
            self.addToast(i18n._("Saved workspace snapshot is invalid"));
            return;
        };
        defer plan.deinit(alloc);

        const fork_restore = workspaceRestoreShouldFork(
            self,
            entry.workspace_key orelse target,
            snapshot_value.workspace.name,
        );
        const results = workspaceControlRestoreAlloc(self, alloc, snapshot_value, &plan) catch |err| switch (err) {
            error.TabMultiSessionUnsupported => {
                self.addToast(i18n._("Restore does not yet support multiple sessions inside one tab"));
                return;
            },
            error.WorkspaceSessionEnvUnsupported => {
                self.addToast(i18n._("Restore does not yet support per-session environment overrides"));
                return;
            },
            error.WorkspaceLayoutMissing,
            error.WorkspaceLayoutInvalid,
            => {
                self.addToast(i18n._("Saved workspace snapshot is missing a valid layout"));
                return;
            },
            else => {
                log.warn("failed to replay workspace restore error={}", .{err});
                self.addToast(i18n._("Failed to restore workspace"));
                return;
            },
        };
        defer {
            for (results.failed_sessions) |failure| {
                alloc.free(failure.code);
                alloc.free(failure.message);
            }
            alloc.free(results.failed_sessions);
            alloc.free(results.restored_session_ids);
            if (results.selection_fallback) |selection_fallback| alloc.free(selection_fallback.reason);
        }

        const restored_workspace_page = self.findWorkspacePageByRuntimeId(results.restored_workspace_id) orelse {
            log.warn("restored workspace replay succeeded but restored page lookup failed workspace_id={}", .{
                results.restored_workspace_id.raw(),
            });
            self.as(gtk.Window).present();
            self.addToast(i18n._("Workspace restored"));
            return;
        };
        const restored_runtime = self.getWorkspaceRuntimeForPage(restored_workspace_page) orelse {
            log.warn("restored workspace replay succeeded but selected page runtime lookup failed", .{});
            self.as(gtk.Window).present();
            self.addToast(i18n._("Workspace restored"));
            return;
        };

        if (fork_restore) {
            const fork_name = allocForkWorkspaceDisplayName(
                self,
                restored_runtime.workspace.workspace_id,
                snapshot_value.workspace.name,
            ) catch |err| {
                log.warn("failed to allocate restore fork workspace name error={}", .{err});
                self.as(gtk.Window).present();
                self.addToast(i18n._("Workspace restored"));
                return;
            };
            defer alloc.free(fork_name);
            const fork_name_z = alloc.dupeZ(u8, fork_name) catch {
                log.warn("failed to allocate restore fork workspace display name", .{});
                self.as(gtk.Window).present();
                self.addToast(i18n._("Workspace restored"));
                return;
            };
            defer alloc.free(fork_name_z);
            const fresh_key = allocFreshWorkspaceKey(restored_runtime.workspace.workspace_id) catch |err| {
                log.warn("failed to allocate restore fork workspace key error={}", .{err});
                self.as(gtk.Window).present();
                self.addToast(i18n._("Workspace restored"));
                return;
            };
            defer alloc.free(fresh_key);
            const next_name = alloc.dupe(u8, fork_name) catch {
                log.warn("failed to persist restore fork workspace name", .{});
                self.as(gtk.Window).present();
                self.addToast(i18n._("Workspace restored"));
                return;
            };
            errdefer alloc.free(next_name);
            const next_slug = alloc.dupe(u8, fresh_key) catch {
                log.warn("failed to persist restore fork workspace key", .{});
                self.as(gtk.Window).present();
                self.addToast(i18n._("Workspace restored"));
                return;
            };
            errdefer alloc.free(next_slug);

            restored_workspace_page.setSidebarTitle(fork_name_z);
            alloc.free(restored_runtime.workspace.name);
            restored_runtime.workspace.name = next_name;
            alloc.free(restored_runtime.workspace.slug);
            restored_runtime.workspace.slug = next_slug;
            if (restored_runtime.workspace.snapshot_ref) |*snapshot_ref| {
                alloc.free(snapshot_ref.saved_at);
                alloc.free(snapshot_ref.path);
                restored_runtime.workspace.snapshot_ref = null;
            }
            self.syncWorkspaceListDescriptors();
        } else {
            updateWorkspaceSnapshotRefAlloc(
                alloc,
                restored_runtime,
                entry.snapshot_id,
                entry.saved_at,
                entry.path,
            );
        }

        self.private().tab_view.setSelectedPage(
            self.private().tab_view.getPage(restored_workspace_page.as(gtk.Widget)),
        );
        self.focusWorkspaceSelection(restored_workspace_page);

        self.as(gtk.Window).present();
        self.addToast(i18n._("Workspace restored"));
    }

    fn actionSplitRight(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Window,
    ) callconv(.c) void {
        self.performBindingAction(.{ .new_split = .right });
    }

    fn actionSplitLeft(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Window,
    ) callconv(.c) void {
        self.performBindingAction(.{ .new_split = .left });
    }

    fn actionSplitUp(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Window,
    ) callconv(.c) void {
        self.performBindingAction(.{ .new_split = .up });
    }

    fn actionSplitDown(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Window,
    ) callconv(.c) void {
        self.performBindingAction(.{ .new_split = .down });
    }

    fn actionCopy(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Window,
    ) callconv(.c) void {
        self.performBindingAction(.{ .copy_to_clipboard = .mixed });
    }

    fn actionPaste(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Window,
    ) callconv(.c) void {
        self.performBindingAction(.paste_from_clipboard);
    }

    fn actionReset(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Window,
    ) callconv(.c) void {
        self.performBindingAction(.reset);
    }

    fn actionClear(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Window,
    ) callconv(.c) void {
        self.performBindingAction(.clear_screen);
    }

    fn actionRingBell(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Window,
    ) callconv(.c) void {
        const priv = self.private();
        const config = if (priv.config) |v| v.get() else return;

        if (config.@"bell-features".system) system: {
            const native = self.as(gtk.Native).getSurface() orelse {
                log.warn("unable to get native surface from window", .{});
                break :system;
            };
            native.beep();
        }

        if (config.@"bell-features".attention) attention: {
            // Dont set urgency if the window is already active.
            if (self.as(gtk.Window).isActive() != 0) break :attention;

            // Request user attention
            self.winproto().setUrgent(true) catch |err| {
                log.warn("winproto failed to set urgency={}", .{err});
            };
        }
    }

    /// Toggle the command palette.
    ///
    /// TODO: accept the surface that toggled the command palette as a parameter
    fn toggleCommandPalette(self: *Window) void {
        const command_palette = self.getOrCreateCommandPalette();
        defer command_palette.unref();

        // Tell the command palette to toggle itself. If the dialog gets
        // presented (instead of hidden) it will be modal over our window.
        command_palette.toggle(self);
    }

    // React to a signal from a command palette asking an action to be performed.
    fn signalCommandPaletteTrigger(_: *CommandPalette, action: *const input.Binding.Action, self: *Self) callconv(.c) void {
        // If the activation actually has an action, perform it.
        self.performBindingAction(action.*);
    }

    /// React to a GTK action requesting that the command palette be toggled.
    fn actionToggleCommandPalette(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Window,
    ) callconv(.c) void {
        // TODO: accept the surface that toggled the command palette as a
        // parameter
        self.toggleCommandPalette();
    }

    /// Toggle the Ghostty inspector for the active surface.
    fn toggleInspector(self: *Self) void {
        const surface = self.getActiveSurface() orelse return;
        _ = surface.controlInspector(.toggle);
    }

    /// React to a GTK action requesting that the Ghostty inspector be toggled.
    fn actionToggleInspector(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Window,
    ) callconv(.c) void {
        // TODO: accept the surface that toggled the command palette as a
        // parameter
        self.toggleInspector();
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
            gobject.ext.ensureType(DebugWarning);
            gobject.ext.ensureType(SplitTree);
            gobject.ext.ensureType(Surface);
            gobject.ext.ensureType(WorkspaceSidebar);
            gobject.ext.ensureType(WorkspacePage);
            gtk.Widget.Class.setTemplateFromResource(
                class.as(gtk.Widget.Class),
                comptime gresource.blueprint(.{
                    .major = 1,
                    .minor = 5,
                    .name = "window",
                }),
            );

            // Properties
            gobject.ext.registerProperties(class, &.{
                properties.@"active-surface".impl,
                properties.config.impl,
                properties.debug.impl,
                properties.@"headerbar-visible".impl,
                properties.@"quick-terminal".impl,
                properties.@"tabs-autohide".impl,
                properties.@"tabs-visible".impl,
                properties.@"tabs-wide".impl,
                properties.@"toolbar-style".impl,
                properties.@"titlebar-style".impl,
            });

            // Bindings
            class.bindTemplateChildPrivate("tab_overview", .{});
            class.bindTemplateChildPrivate("tab_bar", .{});
            class.bindTemplateChildPrivate("tab_view", .{});
            class.bindTemplateChildPrivate("toolbar", .{});
            class.bindTemplateChildPrivate("toast_overlay", .{});
            class.bindTemplateChildPrivate("workspace_split_view", .{});
            class.bindTemplateChildPrivate("workspace_sidebar", .{});

            // Template Callbacks
            class.bindTemplateCallback("realize", &windowRealize);
            class.bindTemplateCallback("new_tab", &btnNewTab);
            class.bindTemplateCallback("toggle_sidebar", &btnToggleSidebar);
            class.bindTemplateCallback("overview_create_tab", &tabOverviewCreateTab);
            class.bindTemplateCallback("overview_notify_open", &tabOverviewOpen);
            class.bindTemplateCallback("close_request", &windowCloseRequest);
            class.bindTemplateCallback("close_page", &tabViewClosePage);
            class.bindTemplateCallback("page_attached", &tabViewPageAttached);
            class.bindTemplateCallback("page_detached", &tabViewPageDetached);
            class.bindTemplateCallback("setup_tab_menu", &setupTabMenu);
            class.bindTemplateCallback("tab_create_window", &tabViewCreateWindow);
            class.bindTemplateCallback("notify_n_pages", &tabViewNPages);
            class.bindTemplateCallback("notify_selected_page", &tabViewSelectedPage);
            class.bindTemplateCallback("notify_config", &propConfig);
            class.bindTemplateCallback("notify_fullscreened", &propFullscreened);
            class.bindTemplateCallback("notify_is_active", &propIsActive);
            class.bindTemplateCallback("notify_maximized", &propMaximized);
            class.bindTemplateCallback("notify_menu_active", &propMenuActive);
            class.bindTemplateCallback("notify_quick_terminal", &propQuickTerminal);
            class.bindTemplateCallback("notify_scale_factor", &propScaleFactor);
            class.bindTemplateCallback("titlebar_style_is_tabs", &closureTitlebarStyleIsTab);
            class.bindTemplateCallback("computed_subtitle", &closureSubtitle);

            // Virtual methods
            gobject.Object.virtual_methods.dispose.implement(class, &dispose);
            gobject.Object.virtual_methods.finalize.implement(class, &finalize);
        }

        pub const as = C.Class.as;
        pub const bindTemplateChildPrivate = C.Class.bindTemplateChildPrivate;
        pub const bindTemplateCallback = C.Class.bindTemplateCallback;
    };
};

pub const WorkspaceControlWorkspace = struct {
    workspace_id: workspace_ids.WorkspaceId,
    selected_window_id: ?workspace_ids.WindowId = null,
    selected_session_id: ?workspace_ids.SessionId = null,
    name: []const u8,
    session_count: usize,
    unread_count: usize,
    has_attention: bool,
    selected: bool,
    restorable: bool,

    pub fn deinit(self: WorkspaceControlWorkspace, alloc: std.mem.Allocator) void {
        alloc.free(self.name);
    }
};

pub const WorkspaceControlSession = struct {
    session_id: workspace_ids.SessionId,
    workspace_id: workspace_ids.WorkspaceId,
    tab_id: workspace_ids.TabId,
    title: []const u8,
    cwd: []const u8,
    focused: bool,
    unread: bool,
    has_attention: bool,

    pub fn deinit(self: WorkspaceControlSession, alloc: std.mem.Allocator) void {
        alloc.free(self.title);
        alloc.free(self.cwd);
    }
};

pub const WorkspaceControlOpenResult = struct {
    workspace_id: workspace_ids.WorkspaceId,
    name: []const u8,
    selected_window_id: ?workspace_ids.WindowId = null,
    selected_session_id: ?workspace_ids.SessionId = null,
};

pub const WorkspaceControlFocusResult = struct {
    focused_session_id: workspace_ids.SessionId,
    tab_id: workspace_ids.TabId,
    window_id: workspace_ids.WindowId,
};

pub const WorkspaceControlSplitDirection = enum {
    right,
    left,
    up,
    down,
};

pub const WorkspaceControlCommand = union(enum) {
    shell: []const u8,
    argv: []const []const u8,
};

pub const WorkspaceControlSplitRequest = struct {
    session: []const u8,
    direction: WorkspaceControlSplitDirection,
    cwd: ?[]const u8 = null,
    command: ?WorkspaceControlCommand = null,
};

pub const WorkspaceControlSplitResult = struct {
    session_id: workspace_ids.SessionId,
    workspace_id: workspace_ids.WorkspaceId,
    tab_id: workspace_ids.TabId,
};

pub const WorkspaceControlCloseResult = struct {
    closed_session_id: workspace_ids.SessionId,
};

pub const WorkspaceControlSaveResult = struct {
    workspace_id: workspace_ids.WorkspaceId,
    snapshot_id: workspace_ids.SnapshotId,
    saved_at: []const u8,
    path: []const u8,

    pub fn deinit(self: *const WorkspaceControlSaveResult, alloc: std.mem.Allocator) void {
        alloc.free(self.saved_at);
        alloc.free(self.path);
    }
};

pub const WorkspaceControlRestoreUnsupported = error{
    TabMultiSessionUnsupported,
    WorkspaceLayoutMissing,
    WorkspaceLayoutInvalid,
    WorkspaceSessionEnvUnsupported,
};

pub const WorkspaceControlResolvedWorkspace = struct {
    window: *Window,
    workspace_page: *WorkspacePage,
    runtime: *workspace_registry.WorkspaceRuntime,
};

const WorkspaceControlResolvedSession = struct {
    window: *Window,
    workspace_page: *WorkspacePage,
    runtime: *workspace_registry.WorkspaceRuntime,
    leaf: *SplitTabs,
    surface: *Surface,
    route: workspace_registry.SessionRoute,
};

pub fn workspaceControlListAlloc(
    self: *Window,
    alloc: std.mem.Allocator,
) ![]WorkspaceControlWorkspace {
    refreshWorkspaceControlRuntime(self);

    var results: std.ArrayList(WorkspaceControlWorkspace) = .empty;
    defer results.deinit(alloc);

    const tab_view = self.getTabView();
    const selected_page = tab_view.getSelectedPage();
    const n = tab_view.getNPages();
    for (0..@intCast(n)) |i| {
        const page = tab_view.getNthPage(@intCast(i));
        const workspace_page = gobject.ext.cast(WorkspacePage, page.getChild()) orelse continue;
        const runtime = self.getWorkspaceRuntimeForPage(workspace_page) orelse continue;
        const summary = runtime.workspace.attention_summary;
        try results.append(alloc, .{
            .workspace_id = runtime.workspace.workspace_id,
            .selected_window_id = runtime.workspace.selected_window_id,
            .selected_session_id = runtime.workspace.selected_session_id,
            .name = try alloc.dupe(u8, runtime.workspace.name),
            .session_count = runtime.sessions.items.len,
            .unread_count = summary.unread_count,
            .has_attention = summary.needs_attention,
            .selected = selected_page != null and selected_page.? == page,
            .restorable = runtime.workspace.snapshot_ref != null,
        });
    }

    return results.toOwnedSlice(alloc);
}

pub fn workspaceControlListSessionsAlloc(
    self: *Window,
    alloc: std.mem.Allocator,
    workspace_target: ?[]const u8,
) ![]WorkspaceControlSession {
    refreshWorkspaceControlRuntime(self);

    const resolved_workspace = resolveWorkspaceControlWorkspace(self, workspace_target) orelse {
        if (workspace_target != null) return error.WorkspaceNotFound;
        return try alloc.alloc(WorkspaceControlSession, 0);
    };

    var results: std.ArrayList(WorkspaceControlSession) = .empty;
    defer results.deinit(alloc);

    for (resolved_workspace.runtime.sessions.items) |session| {
        const title = session.title_override orelse session.title;
        const unread = switch (session.activity_state) {
            .output_pending, .bell_pending => true,
            else => false,
        };
        const has_attention = switch (session.activity_state) {
            .bell_pending, .restore_failed => true,
            else => false,
        };
        try results.append(alloc, .{
            .session_id = session.session_id,
            .workspace_id = session.workspace_id,
            .tab_id = session.tab_id,
            .title = try alloc.dupe(u8, title),
            .cwd = try alloc.dupe(u8, session.cwd),
            .focused = session.focus_state == .focused,
            .unread = unread,
            .has_attention = has_attention,
        });
    }

    return results.toOwnedSlice(alloc);
}

pub fn workspaceControlOpen(
    self: *Window,
    target: []const u8,
    create: bool,
) !WorkspaceControlOpenResult {
    refreshWorkspaceControlRuntime(self);

    if (resolveWorkspaceControlWorkspace(self, target)) |resolved| {
        selectWorkspaceControlPage(resolved.window, resolved.workspace_page, true);
        return .{
            .workspace_id = resolved.runtime.workspace.workspace_id,
            .name = resolved.runtime.workspace.name,
            .selected_window_id = resolved.runtime.workspace.selected_window_id,
            .selected_session_id = resolved.runtime.workspace.selected_session_id,
        };
    }

    if (!create) return error.WorkspaceNotFound;

    const alloc = Application.default().allocator();
    const title = try alloc.dupeZ(u8, target);
    defer alloc.free(title);
    self.newWorkspaceForWindow(null, .{ .title = title });
    const workspace_page = self.getSelectedWorkspacePage() orelse
        return error.WorkspaceNotFound;
    workspace_page.setTitleOverride(title);
    refreshWorkspaceControlRuntime(self);

    const resolved = resolveWorkspaceControlWorkspace(self, null) orelse return error.WorkspaceNotFound;
    selectWorkspaceControlPage(resolved.window, resolved.workspace_page, true);
    return .{
        .workspace_id = resolved.runtime.workspace.workspace_id,
        .name = resolved.runtime.workspace.name,
        .selected_window_id = resolved.runtime.workspace.selected_window_id,
        .selected_session_id = resolved.runtime.workspace.selected_session_id,
    };
}

pub fn workspaceControlFocusSession(
    self: *Window,
    session_target: []const u8,
) !WorkspaceControlFocusResult {
    refreshWorkspaceControlRuntime(self);

    const resolved = resolveWorkspaceControlSession(self, session_target) orelse return error.SessionNotFound;
    selectWorkspaceControlPage(resolved.window, resolved.workspace_page, true);
    _ = resolved.leaf.selectSurface(resolved.surface);
    resolved.window.as(gtk.Window).present();
    resolved.surface.grabFocus();
    refreshWorkspaceControlRuntime(resolved.window);

    return .{
        .focused_session_id = resolved.route.session_id,
        .tab_id = resolved.route.tab_id,
        .window_id = resolved.route.window_id,
    };
}

pub fn workspaceControlSplitSession(
    self: *Window,
    request: WorkspaceControlSplitRequest,
) !WorkspaceControlSplitResult {
    refreshWorkspaceControlRuntime(self);

    const resolved = resolveWorkspaceControlSession(self, request.session) orelse return error.SessionNotFound;
    const split_tree = resolved.workspace_page.getSplitTree();
    const alloc = Application.default().allocator();

    const cwd = if (request.cwd) |value| try alloc.dupeZ(u8, value) else null;
    defer if (cwd) |value| alloc.free(value);

    const command = if (request.command) |value|
        try allocWorkspaceControlCommand(alloc, value)
    else
        null;
    defer if (command) |*value| deinitWorkspaceControlCommand(alloc, value);

    const new_surface = try split_tree.newSplitAtSurface(
        workspaceControlSplitDirection(request.direction),
        resolved.surface,
        resolved.surface,
        .{
            .command = command,
            .working_directory = cwd,
            .focus_new_surface = false,
        },
    );
    refreshWorkspaceControlRuntime(resolved.window);

    const runtime = resolved.window.getWorkspaceRuntimeForPage(resolved.workspace_page) orelse return error.WorkspaceNotFound;
    const session_id = self.private().session_identity_index.sessionForAttachment(@intFromPtr(new_surface)) orelse return error.SessionNotFound;
    const route = workspace_registry.routeForSession(runtime, session_id) orelse return error.SessionNotFound;
    return .{
        .session_id = route.session_id,
        .workspace_id = runtime.workspace.workspace_id,
        .tab_id = route.tab_id,
    };
}

pub fn workspaceControlCloseSession(
    self: *Window,
    session_target: []const u8,
) !WorkspaceControlCloseResult {
    refreshWorkspaceControlRuntime(self);

    const resolved = resolveWorkspaceControlSession(self, session_target) orelse return error.SessionNotFound;
    const closed_session_id = resolved.route.session_id;
    const split_tree = resolved.workspace_page.getSplitTree();
    if (!split_tree.removeSurface(resolved.surface)) return error.SessionNotFound;
    refreshWorkspaceControlRuntime(resolved.window);

    return .{
        .closed_session_id = closed_session_id,
    };
}

const WorkspaceSaveMode = enum {
    explicit,
    autosave,
    shutdown,
};

const SavedScrollbackGeneration = struct {
    session_id: workspace_ids.SessionId,
    generation: u64,
};

const SavedScrollbackState = struct {
    generation: u64,
    path: []const u8,
};

pub fn saveWorkspaceAlloc(
    self: *Window,
    alloc: std.mem.Allocator,
    workspace_page: *WorkspacePage,
) !WorkspaceControlSaveResult {
    return saveWorkspaceWithModeAlloc(
        self,
        alloc,
        workspace_page,
        .explicit,
        null,
    );
}

fn saveWorkspaceWithModeAlloc(
    self: *Window,
    alloc: std.mem.Allocator,
    workspace_page: *WorkspacePage,
    mode: WorkspaceSaveMode,
    autosave_scrollback_budget: ?*AutosaveScrollbackBudget,
) !WorkspaceControlSaveResult {
    self.refreshWorkspaceRegistrySafe();
    const runtime = self.getWorkspaceRuntimeForPage(workspace_page) orelse return error.WorkspaceNotFound;

    const saved_at = try workspace_snapshot.currentUtcTimestampAlloc(alloc);
    errdefer alloc.free(saved_at);

    var dir = try workspace_storage.createDefaultStorageDirAlloc(alloc);
    defer dir.close();
    const storage = workspace_storage.Storage.init(alloc, dir);
    const checkpoint_path = try storage.checkpointFilenameAlloc(runtime.workspace.slug);
    defer alloc.free(checkpoint_path);

    var transaction = try storage.beginTransaction(switch (mode) {
        .autosave => .nonblocking,
        .explicit, .shutdown => .blocking,
    });
    defer transaction.deinit();

    try storage.ensureScrollbackDir(checkpoint_path);
    try storage.checkScrollbackPruneBudgetAssumeLocked(checkpoint_path);

    const snapshot_id = while (true) {
        const candidate = Application.default().runtimeIds().next(.snapshot);
        storage.createScrollbackDirForSnapshotExclusive(
            checkpoint_path,
            candidate,
        ) catch |err| switch (err) {
            error.PathAlreadyExists => continue,
            else => return err,
        };
        break candidate;
    };
    var snapshot_sidecar_committed = false;
    errdefer if (!snapshot_sidecar_committed) {
        storage.deleteScrollbackSnapshotDir(checkpoint_path, snapshot_id) catch |err| {
            log.warn("failed to clean aborted workspace scrollback snapshot path={s} snapshot={} error={}", .{
                checkpoint_path,
                snapshot_id.raw(),
                err,
            });
        };
    };

    var snapshot_value = try workspace_snapshot.fromRuntimeAlloc(
        alloc,
        snapshot_id,
        saved_at,
        runtime,
    );
    defer snapshot_value.deinit(alloc);

    var scrollback_generations: std.ArrayList(SavedScrollbackGeneration) = .empty;
    defer scrollback_generations.deinit(alloc);
    try writeWorkspaceScrollbackAlloc(
        self,
        alloc,
        storage,
        checkpoint_path,
        workspace_page,
        &snapshot_value,
        mode,
        autosave_scrollback_budget,
        &scrollback_generations,
    );

    var commit_state: workspace_storage.Storage.CheckpointCommitState = .uncommitted;
    const path = storage.writeCheckpointTrackedAssumeLocked(
        snapshot_value,
        &commit_state,
    ) catch |err| {
        snapshot_sidecar_committed = commit_state == .committed;
        return err;
    };
    errdefer alloc.free(path);
    snapshot_sidecar_committed = true;
    storage.pruneScrollbackDirForSnapshotAssumeLocked(
        checkpoint_path,
        snapshot_value,
    ) catch |err| {
        log.warn("failed to prune workspace scrollback sidecars path={s} error={}", .{
            checkpoint_path,
            err,
        });
    };

    updateWorkspaceSnapshotRefAlloc(alloc, runtime, snapshot_id, saved_at, path);
    syncSnapshotScrollbackGenerations(self, snapshot_value, scrollback_generations.items);
    return .{
        .workspace_id = runtime.workspace.workspace_id,
        .snapshot_id = snapshot_id,
        .saved_at = saved_at,
        .path = path,
    };
}

fn writeWorkspaceScrollbackAlloc(
    self: *Window,
    alloc: std.mem.Allocator,
    storage: workspace_storage.Storage,
    checkpoint_path: []const u8,
    workspace_page: *WorkspacePage,
    snapshot_value: *workspace_snapshot.Snapshot,
    mode: WorkspaceSaveMode,
    autosave_scrollback_budget: ?*AutosaveScrollbackBudget,
    scrollback_generations: *std.ArrayList(SavedScrollbackGeneration),
) !void {
    const tree = workspace_page.getSurfaceTree() orelse return;
    var unbounded_bytes_remaining: usize = std.math.maxInt(usize);
    const autosave_budget = if (mode == .autosave)
        autosave_scrollback_budget orelse return error.AutosaveScrollbackBudgetRequired
    else
        null;
    const bytes_remaining = if (autosave_budget) |budget|
        &budget.remaining
    else
        &unbounded_bytes_remaining;
    var scrollback_dir = try storage.openScrollbackDirForSnapshot(
        checkpoint_path,
        snapshot_value.snapshot_id,
    );
    defer scrollback_dir.close();

    var it = tree.iterator();
    while (it.next()) |entry| {
        const leaf = entry.view;
        const surface_count = leaf.getSurfaceCount();
        for (0..@intCast(surface_count)) |surface_index| {
            const surface = leaf.getSurfaceAt(@intCast(surface_index)) orelse {
                log.warn("skipping optional scrollback: surface not found index={}", .{surface_index});
                continue;
            };
            const session_id = self.private().session_identity_index.sessionForAttachment(@intFromPtr(surface)) orelse {
                log.warn("skipping optional scrollback: session identity not found", .{});
                continue;
            };
            const core_surface = surface.core() orelse {
                log.warn("skipping optional scrollback: surface not initialized session={}", .{session_id.raw()});
                continue;
            };
            const persisted_scrollback_limit =
                core_surface.persistedScrollbackLimit();
            if (persisted_scrollback_limit == 0) continue;

            const current_generation = core_surface.scrollbackGeneration();
            const saved_state = self.private().scrollback_saved_states.get(session_id);
            const saved_path_exists = if (saved_state) |state|
                try scrollbackFileUsable(
                    storage,
                    state.path,
                    persisted_scrollback_limit,
                )
            else
                false;
            const should_write = shouldWriteScrollbackForSave(
                mode,
                saved_state,
                saved_path_exists,
                session_id,
                checkpoint_path,
                current_generation,
            );
            if (!should_write) {
                const state = saved_state.?;
                try workspace_snapshot.setSessionScrollbackPathAlloc(
                    snapshot_value,
                    alloc,
                    session_id,
                    state.path,
                );
                try scrollback_generations.append(alloc, .{
                    .session_id = session_id,
                    .generation = current_generation,
                });
                continue;
            }

            const relative_path = try storage.scrollbackFilenameAlloc(
                checkpoint_path,
                snapshot_value.snapshot_id,
                session_id,
            );
            defer alloc.free(relative_path);

            const filename = std.fs.path.basename(relative_path);
            const operation_limit: usize = if (autosave_budget) |budget|
                @min(
                    budget.per_session,
                    bytes_remaining.*,
                )
            else
                termio.Termio.max_saved_scrollback_replay_bytes;
            const write_limit = @min(
                operation_limit,
                persisted_scrollback_limit,
            );

            if (write_limit == 0) {
                _ = try preserveExistingScrollbackForDeferredSave(
                    snapshot_value,
                    alloc,
                    scrollback_generations,
                    saved_state,
                    saved_path_exists,
                    checkpoint_path,
                    session_id,
                );
                continue;
            }

            if (try copyUnchangedScrollbackSidecarForSave(
                storage,
                saved_state,
                saved_path_exists,
                checkpoint_path,
                current_generation,
                scrollback_dir,
                filename,
                @intCast(write_limit),
            )) |copied_bytes| {
                if (mode == .autosave) {
                    bytes_remaining.* -= copied_bytes;
                }
                try workspace_snapshot.setSessionScrollbackPathAlloc(
                    snapshot_value,
                    alloc,
                    session_id,
                    relative_path,
                );
                try scrollback_generations.append(alloc, .{
                    .session_id = session_id,
                    .generation = current_generation,
                });
                continue;
            }

            const write_result = core_surface.writeScrollbackFile(
                scrollback_dir,
                filename,
                write_limit,
            ) catch |err| switch (err) {
                error.NoScrollback => continue,
                error.SavedScrollbackTooLarge => {
                    if (mode == .autosave) {
                        bytes_remaining.* -|= write_limit;
                    }
                    _ = try preserveExistingScrollbackForDeferredSave(
                        snapshot_value,
                        alloc,
                        scrollback_generations,
                        saved_state,
                        saved_path_exists,
                        checkpoint_path,
                        session_id,
                    );
                    log.warn("saved scrollback exceeded save budget session={} mode={}", .{
                        session_id.raw(),
                        mode,
                    });
                    continue;
                },
                else => return err,
            };
            if (mode == .autosave) {
                bytes_remaining.* -= write_result.bytes;
            }
            try workspace_snapshot.setSessionScrollbackPathAlloc(
                snapshot_value,
                alloc,
                session_id,
                relative_path,
            );
            try scrollback_generations.append(alloc, .{
                .session_id = session_id,
                .generation = write_result.generation,
            });
        }
    }
}

fn preserveExistingScrollbackForDeferredSave(
    snapshot_value: *workspace_snapshot.Snapshot,
    alloc: std.mem.Allocator,
    scrollback_generations: *std.ArrayList(SavedScrollbackGeneration),
    saved_state: ?SavedScrollbackState,
    saved_path_exists: bool,
    checkpoint_path: []const u8,
    session_id: workspace_ids.SessionId,
) !bool {
    const state = saved_state orelse return false;
    if (!saved_path_exists) return false;
    if (!savedScrollbackPathMatchesCheckpoint(
        state.path,
        checkpoint_path,
        session_id,
    )) return false;

    try workspace_snapshot.setSessionScrollbackPathAlloc(
        snapshot_value,
        alloc,
        session_id,
        state.path,
    );
    try scrollback_generations.append(alloc, .{
        .session_id = session_id,
        .generation = state.generation,
    });
    return true;
}

fn shouldWriteScrollbackForSave(
    mode: WorkspaceSaveMode,
    saved_state: ?SavedScrollbackState,
    saved_path_exists: bool,
    session_id: workspace_ids.SessionId,
    checkpoint_path: []const u8,
    current_generation: u64,
) bool {
    const saved_path_matches_checkpoint = if (saved_state) |state|
        savedScrollbackPathMatchesCheckpoint(state.path, checkpoint_path, session_id)
    else
        false;
    _ = mode;
    return !saved_path_exists or
        !saved_path_matches_checkpoint or
        shouldWriteScrollbackGeneration(saved_state, current_generation);
}

fn savedScrollbackPathMatchesCheckpoint(
    path: []const u8,
    checkpoint_path: []const u8,
    session_id: workspace_ids.SessionId,
) bool {
    return workspace_storage.Storage.validScrollbackSidecarPathForCheckpointAndSession(
        path,
        checkpoint_path,
        session_id,
    );
}

fn shouldWriteScrollbackGeneration(
    saved_state: ?SavedScrollbackState,
    current_generation: u64,
) bool {
    if (saved_state) |state| {
        return state.generation != current_generation;
    }

    // Restored sessions start at generation zero with an existing sidecar.
    // Preserve that sidecar until the terminal actually receives new output.
    return current_generation != 0;
}

fn copyUnchangedScrollbackSidecarForSave(
    storage: workspace_storage.Storage,
    saved_state: ?SavedScrollbackState,
    saved_path_exists: bool,
    checkpoint_path: []const u8,
    current_generation: u64,
    dest_dir: std.fs.Dir,
    dest_filename: []const u8,
    max_bytes: u64,
) !?usize {
    const state = saved_state orelse return null;
    if (!saved_path_exists) return null;
    if (shouldWriteScrollbackGeneration(state, current_generation)) return null;
    if (!workspace_storage.Storage.validScrollbackSidecarPathForCheckpoint(
        state.path,
        checkpoint_path,
    )) return null;

    const copied = storage.copyScrollbackFileToDir(
        state.path,
        dest_dir,
        dest_filename,
        max_bytes,
    ) catch |err| switch (err) {
        error.FileNotFound,
        error.AccessDenied,
        error.PermissionDenied,
        error.NotDir,
        error.SymLinkLoop,
        error.Unsupported,
        error.InvalidWorkspaceScrollbackPath,
        error.InvalidWorkspaceScrollbackFile,
        error.SavedScrollbackTooLarge,
        => return null,
        else => return err,
    };
    return @intCast(copied);
}

fn scrollbackFileUsable(
    storage: workspace_storage.Storage,
    relative_path: []const u8,
    max_bytes: usize,
) !bool {
    const file = storage.openScrollbackFileRead(relative_path) catch |err| switch (err) {
        error.FileNotFound,
        error.AccessDenied,
        error.PermissionDenied,
        error.NotDir,
        error.SymLinkLoop,
        error.Unsupported,
        error.InvalidWorkspaceScrollbackPath,
        => return false,
        else => return err,
    };
    defer file.close();

    const stat = file.stat() catch return false;
    return stat.kind == .file and
        stat.size <= max_bytes;
}

fn syncSnapshotScrollbackGenerations(
    self: *Window,
    snapshot_value: workspace_snapshot.Snapshot,
    scrollback_generations: []const SavedScrollbackGeneration,
) void {
    for (snapshot_value.sessions) |session| {
        if (session.scrollback_path == null) {
            removeSavedScrollbackState(self, session.session_id);
            continue;
        }

        const generation = for (scrollback_generations) |entry| {
            if (entry.session_id == session.session_id) break entry.generation;
        } else {
            removeSavedScrollbackState(self, session.session_id);
            continue;
        };
        setSavedScrollbackStateAlloc(
            self,
            Application.default().allocator(),
            session.session_id,
            generation,
            session.scrollback_path.?,
        ) catch |err| {
            log.warn("failed to record scrollback state session={} error={}", .{
                session.session_id.raw(),
                err,
            });
        };
    }
}

fn syncRestoredScrollbackStates(self: *Window, sessions: []const workspace_restore.SessionPlan) void {
    const alloc = Application.default().allocator();
    for (sessions) |session| {
        const path = session.scrollback_path orelse {
            removeSavedScrollbackState(self, session.session_id);
            continue;
        };
        if (!restoredScrollbackSidecarUsable(alloc, path)) {
            removeSavedScrollbackState(self, session.session_id);
            continue;
        }
        setSavedScrollbackStateAlloc(
            self,
            alloc,
            session.session_id,
            0,
            path,
        ) catch |err| {
            log.warn("failed to record restored scrollback state session={} error={}", .{
                session.session_id.raw(),
                err,
            });
        };
    }
}

fn restoredScrollbackSidecarUsable(
    alloc: std.mem.Allocator,
    relative_path: []const u8,
) bool {
    if (!validWorkspaceScrollbackPath(relative_path)) return false;
    const file = openRestoreScrollbackFile(alloc, relative_path) catch return false;
    defer file.close();

    const stat = file.stat() catch return false;
    return stat.kind == .file and
        stat.size <= termio.Termio.max_saved_scrollback_replay_bytes;
}

fn setSavedScrollbackStateAlloc(
    self: *Window,
    alloc: std.mem.Allocator,
    session_id: workspace_ids.SessionId,
    generation: u64,
    path: []const u8,
) !void {
    const owned_path = try alloc.dupe(u8, path);
    errdefer alloc.free(owned_path);

    const next: SavedScrollbackState = .{
        .generation = generation,
        .path = owned_path,
    };
    if (try self.private().scrollback_saved_states.fetchPut(session_id, next)) |old| {
        alloc.free(old.value.path);
    }
}

fn removeSavedScrollbackState(self: *Window, session_id: workspace_ids.SessionId) void {
    if (self.private().scrollback_saved_states.fetchRemove(session_id)) |removed| {
        Application.default().allocator().free(removed.value.path);
    }
}

fn pruneSavedScrollbackStates(
    alloc: std.mem.Allocator,
    states: *std.AutoHashMap(workspace_ids.SessionId, SavedScrollbackState),
    live_session_ids: []const workspace_ids.SessionId,
) void {
    var stale_session_ids: std.ArrayList(workspace_ids.SessionId) = .empty;
    defer stale_session_ids.deinit(alloc);

    var it = states.keyIterator();
    while (it.next()) |session_id| {
        if (containsSessionId(live_session_ids, session_id.*)) continue;
        stale_session_ids.append(alloc, session_id.*) catch continue;
    }

    for (stale_session_ids.items) |session_id| {
        if (states.fetchRemove(session_id)) |removed| {
            alloc.free(removed.value.path);
        }
    }
}

fn containsSessionId(
    values: []const workspace_ids.SessionId,
    needle: workspace_ids.SessionId,
) bool {
    for (values) |value| {
        if (value == needle) return true;
    }
    return false;
}

fn deinitSavedScrollbackStates(self: *Window) void {
    const alloc = Application.default().allocator();
    var it = self.private().scrollback_saved_states.valueIterator();
    while (it.next()) |state| {
        alloc.free(state.path);
    }
}

pub fn workspaceControlRestoreAlloc(
    self: *Window,
    alloc: std.mem.Allocator,
    value: workspace_snapshot.Snapshot,
    plan: *const workspace_restore.Plan,
) !workspace_model.RestoreResults {
    var live_plan = try remapRestorePlanForLiveRuntimeAlloc(alloc, plan);
    defer live_plan.deinit(alloc);

    try validateWorkspaceRestoreReplaySupported(value, &live_plan);

    const tab_view = self.getTabView();
    const previously_selected_page = tab_view.getSelectedPage();
    const page = self.newEmptyWorkspacePage(tab_view.getNPages(), false);
    errdefer tab_view.closePage(page);

    const workspace_page = gobject.ext.cast(WorkspacePage, page.getChild()) orelse return error.WorkspaceNotFound;
    const page_key = @intFromPtr(workspace_page);
    const priv = self.private();
    const had_previous_workspace = priv.workspace_ids_by_page.get(page_key) != null;
    const previous_workspace_id = priv.workspace_ids_by_page.get(page_key);
    errdefer {
        if (priv.workspace_ids_by_page.get(page_key)) |workspace_id| {
            _ = priv.runtime_registry.removeWorkspace(workspace_id);
            _ = priv.workspace_ids_by_page.remove(page_key);
        }
        if (had_previous_workspace and previous_workspace_id != null) {
            priv.workspace_ids_by_page.put(page_key, previous_workspace_id.?) catch {};
        }
    }

    if (priv.workspace_ids_by_page.get(page_key)) |existing_workspace_id| {
        _ = priv.runtime_registry.removeWorkspace(existing_workspace_id);
        _ = priv.workspace_ids_by_page.remove(page_key);
    }
    try priv.workspace_ids_by_page.put(page_key, live_plan.workspace_id);

    if (value.workspace.name.len > 0) {
        const title_override = try alloc.dupeZ(u8, value.workspace.name);
        defer alloc.free(title_override);
        workspace_page.setTitleOverride(title_override);
    }

    var built_tree = try buildWorkspaceRestoreTreeAlloc(self, alloc, value, &live_plan);
    defer built_tree.deinit();
    workspace_page.getSplitTree().setTree(&built_tree);
    if (previously_selected_page) |selected_page| tab_view.setSelectedPage(selected_page);

    self.refreshWorkspaceRegistrySafe();
    const runtime = self.getWorkspaceRuntimeForPage(workspace_page) orelse return error.WorkspaceNotFound;
    if (value.workspace.workspace_key) |workspace_key| {
        alloc.free(runtime.workspace.slug);
        runtime.workspace.slug = try alloc.dupe(u8, workspace_key);
    }

    const window_id = runtime.windows.items[0].window_id;
    var outcomes = try alloc.alloc(workspace_restore.ReplayOutcome, live_plan.sessions.len);
    defer alloc.free(outcomes);
    for (live_plan.sessions, 0..) |session, index| {
        outcomes[index] = .{ .restored = .{
            .session_id = session.session_id,
            .window_id = window_id,
            .split_id = session.split_id,
            .tab_id = session.tab_id,
        } };
    }

    const finalized = try workspace_restore.finalizeAlloc(alloc, &live_plan, outcomes);
    defer finalized.deinit(alloc);

    self.refreshWorkspaceRegistrySafe();
    const restored_runtime = self.getWorkspaceRuntimeForPage(workspace_page) orelse return error.WorkspaceNotFound;
    var results = try cloneRestoreResultsAlloc(alloc, finalized.results);
    results.restored_workspace_id = restored_runtime.workspace.workspace_id;
    syncRestoredScrollbackStates(self, live_plan.sessions);
    return results;
}

fn remapRestorePlanForLiveRuntimeAlloc(
    alloc: std.mem.Allocator,
    plan: *const workspace_restore.Plan,
) !workspace_restore.Plan {
    const app = Application.default();
    var split_ids = std.AutoHashMap(workspace_ids.SplitId, workspace_ids.SplitId).init(alloc);
    defer split_ids.deinit();
    var tab_ids = std.AutoHashMap(workspace_ids.TabId, workspace_ids.TabId).init(alloc);
    defer tab_ids.deinit();
    var session_ids = std.AutoHashMap(workspace_ids.SessionId, workspace_ids.SessionId).init(alloc);
    defer session_ids.deinit();

    const splits = try alloc.dupe(workspace_restore.SplitPlan, plan.splits);
    errdefer alloc.free(splits);
    for (splits) |*split| {
        const live_split_id = app.runtimeIds().next(.split);
        try split_ids.put(split.split_id, live_split_id);
        split.split_id = live_split_id;
    }

    const tabs = try alloc.dupe(workspace_restore.TabPlan, plan.tabs);
    errdefer alloc.free(tabs);
    for (tabs) |*tab| {
        const live_tab_id = app.runtimeIds().next(.tab);
        try tab_ids.put(tab.tab_id, live_tab_id);
        tab.split_id = split_ids.get(tab.split_id) orelse return error.WorkspaceLayoutInvalid;
        tab.tab_id = live_tab_id;
    }

    const tab_order = try alloc.dupe(usize, plan.tab_order);
    errdefer alloc.free(tab_order);

    const sessions = try alloc.dupe(workspace_restore.SessionPlan, plan.sessions);
    errdefer alloc.free(sessions);
    for (sessions) |*session| {
        const live_session_id = app.runtimeIds().next(.session);
        try session_ids.put(session.session_id, live_session_id);
        session.split_id = split_ids.get(session.split_id) orelse return error.WorkspaceLayoutInvalid;
        session.tab_id = tab_ids.get(session.tab_id) orelse return error.WorkspaceLayoutInvalid;
        session.session_id = live_session_id;
    }

    return .{
        .snapshot_id = plan.snapshot_id,
        .workspace_id = app.runtimeIds().next(.workspace),
        .workspace_name = plan.workspace_name,
        .selection_hints = .{
            .selected_window_id = null,
            .selected_split_id = if (plan.selection_hints.selected_split_id) |split_id| split_ids.get(split_id) else null,
            .selected_tab_id = if (plan.selection_hints.selected_tab_id) |tab_id| tab_ids.get(tab_id) else null,
            .selected_session_id = if (plan.selection_hints.selected_session_id) |session_id| session_ids.get(session_id) else null,
        },
        .splits = splits,
        .tabs = tabs,
        .tab_order = tab_order,
        .sessions = sessions,
    };
}

fn refreshWorkspaceControlRuntime(window: *Window) void {
    window.refreshWorkspaceRegistrySafe();
}

fn validateWorkspaceRestoreReplaySupported(
    value: workspace_snapshot.Snapshot,
    plan: *const workspace_restore.Plan,
) !void {
    if (value.workspace.layout_root_node_id == null) return error.WorkspaceLayoutMissing;

    for (plan.tabs) |tab| {
        if (tab.session_len != 1) return error.TabMultiSessionUnsupported;
    }

    for (value.sessions) |session| {
        if (session.env_overrides.len > 0) return error.WorkspaceSessionEnvUnsupported;
    }

    for (value.layout) |entry| {
        if (entry.node_type != .split) continue;
        if (entry.tab_id != null) continue;
        const child_ids = entry.child_ids orelse return error.WorkspaceLayoutInvalid;
        if (child_ids.len != 2) return error.WorkspaceLayoutInvalid;
    }
}

fn buildWorkspaceRestoreTreeAlloc(
    self: *Window,
    alloc: std.mem.Allocator,
    value: workspace_snapshot.Snapshot,
    plan: *const workspace_restore.Plan,
) !SplitTabs.Tree {
    var split_map = std.AutoHashMap(workspace_ids.SplitId, workspace_restore.SplitPlan).init(alloc);
    defer split_map.deinit();
    var split_root_map = std.StringHashMap(workspace_ids.SplitId).init(alloc);
    defer split_root_map.deinit();
    var layout_map = std.StringHashMap(workspace_snapshot.LayoutNodeRecord).init(alloc);
    defer layout_map.deinit();

    for (plan.splits) |split| {
        const layout_root_id = split.layout_root_id orelse return error.WorkspaceLayoutInvalid;
        try split_map.put(split.split_id, split);
        try split_root_map.put(layout_root_id, split.split_id);
    }
    for (value.layout) |entry| {
        try layout_map.put(entry.layout_node_id, entry);
    }

    const root_layout_node_id = value.workspace.layout_root_node_id orelse return error.WorkspaceLayoutMissing;
    return buildWorkspaceRestoreTreeFromNodeAlloc(
        self,
        alloc,
        plan,
        &split_map,
        &split_root_map,
        &layout_map,
        root_layout_node_id,
        plan.workspace_id,
    );
}

fn buildWorkspaceRestoreTreeFromNodeAlloc(
    self: *Window,
    alloc: std.mem.Allocator,
    plan: *const workspace_restore.Plan,
    split_map: *const std.AutoHashMap(workspace_ids.SplitId, workspace_restore.SplitPlan),
    split_root_map: *const std.StringHashMap(workspace_ids.SplitId),
    layout_map: *const std.StringHashMap(workspace_snapshot.LayoutNodeRecord),
    layout_node_id: []const u8,
    workspace_id: workspace_ids.WorkspaceId,
) !SplitTabs.Tree {
    const entry = layout_map.get(layout_node_id) orelse return error.WorkspaceLayoutInvalid;
    return switch (entry.node_type) {
        .split_root => blk: {
            const split_id = split_root_map.get(layout_node_id) orelse return error.WorkspaceLayoutInvalid;
            const split = split_map.get(split_id) orelse return error.WorkspaceLayoutInvalid;
            break :blk try buildWorkspaceRestoreLeafTreeAlloc(self, alloc, plan, split, workspace_id);
        },
        .split => blk: {
            if (entry.tab_id != null) return error.TabMultiSessionUnsupported;
            const child_ids = entry.child_ids orelse return error.WorkspaceLayoutInvalid;
            if (child_ids.len != 2) return error.WorkspaceLayoutInvalid;

            var left = try buildWorkspaceRestoreTreeFromNodeAlloc(
                self,
                alloc,
                plan,
                split_map,
                split_root_map,
                layout_map,
                child_ids[0],
                workspace_id,
            );
            defer left.deinit();
            var right = try buildWorkspaceRestoreTreeFromNodeAlloc(
                self,
                alloc,
                plan,
                split_map,
                split_root_map,
                layout_map,
                child_ids[1],
                workspace_id,
            );
            defer right.deinit();

            const direction: SplitTabs.Tree.Split.Direction = switch (entry.split_direction orelse return error.WorkspaceLayoutInvalid) {
                .right => .right,
                .down => .down,
                else => return error.WorkspaceLayoutInvalid,
            };
            const ratio = @as(f16, @floatCast(entry.ratio orelse 0.5));
            break :blk try left.split(alloc, .root, direction, ratio, &right);
        },
        else => error.WorkspaceLayoutInvalid,
    };
}

fn buildWorkspaceRestoreLeafTreeAlloc(
    self: *Window,
    alloc: std.mem.Allocator,
    plan: *const workspace_restore.Plan,
    split_plan: workspace_restore.SplitPlan,
    workspace_id: workspace_ids.WorkspaceId,
) !SplitTabs.Tree {
    if (split_plan.tab_len == 0) return error.WorkspaceLayoutInvalid;

    const first_tab_plan = plan.tabs[split_plan.tab_start];
    const first_session_plan = plan.sessions[first_tab_plan.session_start];
    var first_surface = try createRestoreSurfaceAlloc(alloc, first_session_plan);
    defer first_surface.unref();
    _ = first_surface.refSink();

    const split_tabs = SplitTabs.new(first_surface);
    defer split_tabs.unref();
    _ = split_tabs.refSink();

    bindRestoredSplitId(self, split_tabs, split_plan.split_id) catch return error.OutOfMemory;
    const first_tab = split_tabs.getTabAt(0) orelse return error.WorkspaceLayoutInvalid;
    bindRestoredTabId(self, first_tab, first_tab_plan.tab_id) catch return error.OutOfMemory;
    try bindRestoredSessionIdentityAlloc(self, alloc, workspace_id, split_plan.split_id, first_tab_plan.tab_id, first_session_plan.session_id, first_surface);
    if (first_tab_plan.title_override) |title_override| {
        const title_override_z = try alloc.dupeZ(u8, title_override);
        defer alloc.free(title_override_z);
        first_tab.setTitleOverride(title_override_z);
    }

    var selected_surface: ?*Surface = if (first_tab_plan.selected_hint) first_surface else null;

    var tab_offset: usize = 1;
    while (tab_offset < split_plan.tab_len) : (tab_offset += 1) {
        const tab_plan = plan.tabs[split_plan.tab_start + tab_offset];
        const session_plan = plan.sessions[tab_plan.session_start];
        var surface = try createRestoreSurfaceAlloc(alloc, session_plan);
        defer surface.unref();
        _ = surface.refSink();

        _ = split_tabs.addSurface(surface, tab_plan.selected_hint);
        const tab = split_tabs.getTabAt(@intCast(tab_offset)) orelse return error.WorkspaceLayoutInvalid;
        bindRestoredTabId(self, tab, tab_plan.tab_id) catch return error.OutOfMemory;
        try bindRestoredSessionIdentityAlloc(self, alloc, workspace_id, split_plan.split_id, tab_plan.tab_id, session_plan.session_id, surface);
        if (tab_plan.title_override) |title_override| {
            const title_override_z = try alloc.dupeZ(u8, title_override);
            defer alloc.free(title_override_z);
            tab.setTitleOverride(title_override_z);
        }
        if (tab_plan.selected_hint) selected_surface = surface;
    }

    if (selected_surface) |surface| {
        _ = split_tabs.selectSurfaceWithoutFocus(surface);
    }

    return SplitTabs.Tree.init(alloc, split_tabs);
}

fn createRestoreSurfaceAlloc(
    alloc: std.mem.Allocator,
    session: workspace_restore.SessionPlan,
) !*Surface {
    var command = try allocRestoreCommand(alloc, session.command);
    defer if (command) |*value| deinitRestoreCommand(alloc, value);
    const cwd = try alloc.dupeZ(u8, session.cwd);
    defer alloc.free(cwd);
    const title_override = if (session.title_override) |value|
        try alloc.dupeZ(u8, value)
    else
        null;
    defer if (title_override) |value| alloc.free(value);
    var initial_scrollback_file = if (session.scrollback_path) |path| path: {
        break :path openRestoreScrollbackFile(alloc, path) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => {
                log.warn("skipping saved scrollback restore session={} path={s} error={}", .{
                    session.session_id.raw(),
                    path,
                    err,
                });
                break :path null;
            },
        };
    } else null;
    errdefer if (initial_scrollback_file) |file| file.close();

    const surface = Surface.new(.{
        .command = command,
        .working_directory = cwd,
        .initial_scrollback_file = initial_scrollback_file,
        .title = title_override,
    });
    var surface_owned = true;
    errdefer if (surface_owned) surface.unref();
    initial_scrollback_file = null;
    if (session.cwd.len > 0) {
        surface.setPwd(cwd);
        if (title_override == null) {
            const display_cwd = try allocRestoreDisplayPath(alloc, session.cwd);
            defer alloc.free(display_cwd);
            const display_cwd_z = try alloc.dupeZ(u8, display_cwd);
            defer alloc.free(display_cwd_z);
            surface.setTitle(display_cwd_z);
        }
    }
    surface_owned = false;
    return surface;
}

fn openRestoreScrollbackFile(
    alloc: std.mem.Allocator,
    relative_path: []const u8,
) !std.fs.File {
    if (!workspace_storage.Storage.validScrollbackSidecarPath(relative_path)) return error.InvalidWorkspaceScrollbackPath;

    var dir = try workspace_storage.openDefaultStorageDirAlloc(alloc) orelse return error.FileNotFound;
    defer dir.close();

    const storage = workspace_storage.Storage.init(alloc, dir);
    return try storage.openScrollbackFileRead(relative_path);
}

fn validWorkspaceScrollbackPath(path: []const u8) bool {
    return workspace_storage.Storage.validScrollbackSidecarPath(path);
}

fn allocRestoreDisplayPath(
    alloc: std.mem.Allocator,
    path: []const u8,
) ![]u8 {
    var home_buf: [std.fs.max_path_bytes]u8 = undefined;
    const home = internal_os.home(&home_buf) catch null;
    if (home) |home_path| {
        if (std.mem.eql(u8, path, home_path)) {
            return try alloc.dupe(u8, "~");
        }

        if (path.len > home_path.len and
            std.mem.startsWith(u8, path, home_path) and
            path[home_path.len] == std.fs.path.sep)
        {
            return try std.fmt.allocPrint(alloc, "~{s}", .{path[home_path.len..]});
        }
    }

    return try alloc.dupe(u8, path);
}

fn allocRestoreCommand(
    alloc: std.mem.Allocator,
    command: workspace_model.Command,
) !?configpkg.Command {
    return switch (command) {
        .shell => |value| .{ .shell = try alloc.dupeZ(u8, value) },
        .argv => |argv| blk: {
            var copied = try alloc.alloc([:0]const u8, argv.len);
            var initialized: usize = 0;
            errdefer {
                for (copied[0..initialized]) |item| alloc.free(item);
                alloc.free(copied);
            }
            for (argv, 0..) |item, index| {
                copied[index] = try alloc.dupeZ(u8, item);
                initialized = index + 1;
            }
            break :blk .{ .direct = copied };
        },
    };
}

fn deinitRestoreCommand(
    alloc: std.mem.Allocator,
    command: *configpkg.Command,
) void {
    switch (command.*) {
        .shell => |value| alloc.free(value),
        .direct => |argv| {
            for (argv) |item| alloc.free(item);
            alloc.free(argv);
        },
    }
}

fn findRestoreSplitPlan(
    plan: *const workspace_restore.Plan,
    split_id: workspace_ids.SplitId,
) ?workspace_restore.SplitPlan {
    for (plan.splits) |split| {
        if (split.split_id == split_id) return split;
    }
    return null;
}

fn bindRestoredSplitId(
    self: *Window,
    leaf: *SplitTabs,
    split_id: workspace_ids.SplitId,
) !void {
    Application.default().runtimeIds().observe(split_id);
    try self.private().split_ids_by_leaf.put(@intFromPtr(leaf), split_id);
}

fn bindRestoredTabId(
    self: *Window,
    tab: *Tab,
    tab_id: workspace_ids.TabId,
) !void {
    Application.default().runtimeIds().observe(tab_id);
    try self.private().tab_ids_by_widget.put(@intFromPtr(tab), tab_id);
}

fn bindRestoredSessionIdentityAlloc(
    self: *Window,
    alloc: std.mem.Allocator,
    workspace_id: workspace_ids.WorkspaceId,
    split_id: workspace_ids.SplitId,
    tab_id: workspace_ids.TabId,
    session_id: workspace_ids.SessionId,
    surface: *Surface,
) !void {
    Application.default().runtimeIds().observe(session_id);
    const session_path = try std.fmt.allocPrint(
        alloc,
        "ws-{d}/split-{d}/tab-{d}",
        .{ workspace_id.raw(), split_id.raw(), tab_id.raw() },
    );
    defer alloc.free(session_path);
    try self.private().session_identity_index.bindSession(
        session_id,
        @intFromPtr(surface),
        session_path,
    );
}

fn cloneRestoreResultsAlloc(
    alloc: std.mem.Allocator,
    value: workspace_model.RestoreResults,
) !workspace_model.RestoreResults {
    var failed_sessions = try alloc.alloc(workspace_model.RestoreFailure, value.failed_sessions.len);
    errdefer alloc.free(failed_sessions);
    var initialized_failed_sessions: usize = 0;
    for (value.failed_sessions, 0..) |failure, index| {
        var code: ?[]u8 = try alloc.dupe(u8, failure.code);
        errdefer if (code) |value_code| alloc.free(value_code);
        var message: ?[]u8 = try alloc.dupe(u8, failure.message);
        errdefer if (message) |value_message| alloc.free(value_message);
        failed_sessions[index] = .{
            .session_id = failure.session_id,
            .code = code.?,
            .message = message.?,
        };
        code = null;
        message = null;
        initialized_failed_sessions = index + 1;
    }
    errdefer {
        for (failed_sessions[0..initialized_failed_sessions]) |failure| {
            alloc.free(failure.code);
            alloc.free(failure.message);
        }
        alloc.free(failed_sessions);
    }

    const restored_session_ids = try alloc.dupe(workspace_ids.SessionId, value.restored_session_ids);
    errdefer alloc.free(restored_session_ids);
    const selection_fallback = if (value.selection_fallback) |fallback| fallback: {
        const reason = try alloc.dupe(u8, fallback.reason);
        errdefer alloc.free(reason);
        break :fallback workspace_model.SelectionFallback{
            .window_id = fallback.window_id,
            .tab_id = fallback.tab_id,
            .session_id = fallback.session_id,
            .reason = reason,
        };
    } else null;
    errdefer if (selection_fallback) |fallback| alloc.free(fallback.reason);

    return .{
        .restored_workspace_id = value.restored_workspace_id,
        .restored_session_ids = restored_session_ids,
        .failed_sessions = failed_sessions,
        .selection_fallback = selection_fallback,
    };
}

fn updateWorkspaceSnapshotRefAlloc(
    alloc: std.mem.Allocator,
    runtime: anytype,
    snapshot_id: workspace_ids.SnapshotId,
    saved_at: []const u8,
    path: []const u8,
) void {
    const next_saved_at = alloc.dupe(u8, saved_at) catch return;
    errdefer alloc.free(next_saved_at);
    const next_path = alloc.dupe(u8, path) catch return;
    errdefer alloc.free(next_path);

    const next_snapshot_ref: workspace_model.WorkspaceSnapshotRef = .{
        .snapshot_id = snapshot_id,
        .saved_at = next_saved_at,
        .path = next_path,
    };

    if (runtime.workspace.snapshot_ref) |*snapshot_ref| {
        alloc.free(snapshot_ref.saved_at);
        alloc.free(snapshot_ref.path);
    }
    runtime.workspace.snapshot_ref = next_snapshot_ref;
}

fn clearWorkspaceSnapshotRefAlloc(
    alloc: std.mem.Allocator,
    runtime: anytype,
) void {
    if (runtime.workspace.snapshot_ref) |*snapshot_ref| {
        alloc.free(snapshot_ref.saved_at);
        alloc.free(snapshot_ref.path);
        runtime.workspace.snapshot_ref = null;
    }
}

fn allocFreshWorkspaceKey(
    workspace_id: workspace_ids.WorkspaceId,
) ![]u8 {
    return std.fmt.allocPrint(
        Application.default().allocator(),
        "workspace-{d}-{d}",
        .{
            @as(u64, @intCast(std.time.microTimestamp())),
            workspace_id.raw(),
        },
    );
}

fn workspaceRestoreShouldFork(
    self: *Window,
    workspace_key: []const u8,
    workspace_name: []const u8,
) bool {
    const priv = self.private();
    for (priv.runtime_registry.workspaces.items) |*runtime| {
        if (std.mem.eql(u8, runtime.workspace.name, workspace_name)) return true;
        if (runtime.workspace.snapshot_ref == null) continue;
        if (std.mem.eql(u8, runtime.workspace.slug, workspace_key)) return true;
    }

    return false;
}

fn allocForkWorkspaceDisplayName(
    self: *Window,
    restored_workspace_id: workspace_ids.WorkspaceId,
    base_name: []const u8,
) ![]u8 {
    const alloc = Application.default().allocator();
    if (!workspaceNameExists(self, restored_workspace_id, base_name)) {
        return try alloc.dupe(u8, base_name);
    }

    var suffix: usize = 1;
    while (true) : (suffix += 1) {
        const candidate = try std.fmt.allocPrint(alloc, "{s}-{d}", .{ base_name, suffix });
        errdefer alloc.free(candidate);
        if (!workspaceNameExists(self, restored_workspace_id, candidate)) {
            return candidate;
        }
        alloc.free(candidate);
    }
}

fn workspaceNameExists(
    self: *Window,
    excluded_workspace_id: workspace_ids.WorkspaceId,
    name: []const u8,
) bool {
    for (self.private().runtime_registry.workspaces.items) |*runtime| {
        if (runtime.workspace.workspace_id == excluded_workspace_id) continue;
        if (std.mem.eql(u8, runtime.workspace.name, name)) return true;
    }
    return false;
}

fn revealPathInFileManager(path: []const u8) !void {
    var err: ?*glib.Error = null;
    defer if (err) |e| e.free();

    const dbus = gio.busGetSync(.session, null, &err) orelse return error.DBusUnavailable;
    defer dbus.unref();
    if (err != null) return error.DBusUnavailable;

    const path_z = try std.heap.c_allocator.dupeZ(u8, path);
    defer std.heap.c_allocator.free(path_z);
    const uri_z = glib.filenameToUri(path_z, null, &err) orelse return error.InvalidPath;
    defer glib.free(uri_z);
    if (err != null) return error.InvalidPath;

    const params_type = glib.VariantType.new("(ass)");
    defer params_type.free();
    const params_builder = glib.VariantBuilder.new(params_type);
    defer params_builder.unref();

    const uris_type = glib.VariantType.new("as");
    defer uris_type.free();
    params_builder.open(uris_type);
    params_builder.add("s", uri_z);
    params_builder.close();
    params_builder.add("s", "");

    const params = params_builder.end();
    const reply = dbus.callSync(
        "org.freedesktop.FileManager1",
        "/org/freedesktop/FileManager1",
        "org.freedesktop.FileManager1",
        "ShowItems",
        params,
        null,
        .{},
        -1,
        null,
        &err,
    ) orelse return error.RevealFailed;
    defer reply.unref();
    if (err != null) return error.RevealFailed;
}

fn workspaceSnapshotPathAlloc(
    self: *Window,
    alloc: std.mem.Allocator,
    workspace_page: *WorkspacePage,
) !?[]u8 {
    self.refreshWorkspaceRegistrySafe();
    const runtime = self.getWorkspaceRuntimeForPage(workspace_page) orelse return null;
    const snapshot_ref = runtime.workspace.snapshot_ref orelse return null;

    const storage_path = try internal_os.xdg.state(alloc, .{
        .subdir = "ghostty/workspaces",
    });
    defer alloc.free(storage_path);
    return try std.fs.path.join(alloc, &.{ storage_path, snapshot_ref.path });
}

fn findSavedWorkspaceCatalogEntry(
    entries: []const workspace_snapshot.CatalogEntry,
    target: []const u8,
) ?workspace_snapshot.CatalogEntry {
    for (entries) |entry| {
        const workspace_key = entry.workspace_key orelse continue;
        if (std.mem.eql(u8, workspace_key, target)) return entry;
    }

    for (entries) |entry| {
        if (std.mem.eql(u8, entry.workspace_name, target)) return entry;
    }

    return null;
}

fn findSavedWorkspaceCatalogEntryForRuntime(
    entries: []const workspace_snapshot.CatalogEntry,
    runtime: *const workspace_registry.WorkspaceRuntime,
) ?workspace_snapshot.CatalogEntry {
    if (runtime.workspace.snapshot_ref) |snapshot_ref| {
        for (entries) |entry| {
            if (std.mem.eql(u8, entry.path, snapshot_ref.path)) return entry;
        }
    }

    if (findSavedWorkspaceCatalogEntry(entries, runtime.workspace.slug)) |entry| return entry;
    return findSavedWorkspaceCatalogEntry(entries, runtime.workspace.name);
}

pub fn resolveWorkspaceControlWorkspace(
    window: *Window,
    target: ?[]const u8,
) ?WorkspaceControlResolvedWorkspace {
    const tab_view = window.getTabView();
    const target_id = if (target) |value| parseWorkspaceControlWorkspaceRef(value) else null;
    const selected_page = window.getSelectedWorkspacePage();
    const n = tab_view.getNPages();

    for (0..@intCast(n)) |i| {
        const page = tab_view.getNthPage(@intCast(i));
        const workspace_page = gobject.ext.cast(WorkspacePage, page.getChild()) orelse continue;
        const runtime = window.getWorkspaceRuntimeForPage(workspace_page) orelse continue;

        if (target == null) {
            if (selected_page != null and selected_page.? == workspace_page) {
                return .{
                    .window = window,
                    .workspace_page = workspace_page,
                    .runtime = runtime,
                };
            }
            continue;
        }

        if (target_id) |workspace_id| {
            if (runtime.workspace.workspace_id != workspace_id) continue;
            return .{
                .window = window,
                .workspace_page = workspace_page,
                .runtime = runtime,
            };
        }

        if (std.mem.eql(u8, runtime.workspace.slug, target.?)) {
            return .{
                .window = window,
                .workspace_page = workspace_page,
                .runtime = runtime,
            };
        }

        const title = workspace_page.getSidebarTitle() orelse runtime.workspace.name;
        if (!std.mem.eql(u8, title, target.?)) {
            if (!std.mem.eql(u8, runtime.workspace.name, target.?)) continue;
        }

        return .{
            .window = window,
            .workspace_page = workspace_page,
            .runtime = runtime,
        };
    }

    return null;
}

fn resolveWorkspaceControlSession(
    window: *Window,
    target: []const u8,
) ?WorkspaceControlResolvedSession {
    const session_id = parseWorkspaceControlSessionRef(target) orelse return null;
    const tab_view = window.getTabView();
    const n = tab_view.getNPages();

    for (0..@intCast(n)) |i| {
        const page = tab_view.getNthPage(@intCast(i));
        const workspace_page = gobject.ext.cast(WorkspacePage, page.getChild()) orelse continue;
        const runtime = window.getWorkspaceRuntimeForPage(workspace_page) orelse continue;
        const route = workspace_registry.routeForSession(runtime, session_id) orelse continue;
        const tree = workspace_page.getSurfaceTree() orelse continue;

        var it = tree.iterator();
        while (it.next()) |entry| {
            const leaf = entry.view;
            const surface_count = leaf.getSurfaceCount();
            for (0..@intCast(surface_count)) |surface_index| {
                const surface = leaf.getSurfaceAt(@intCast(surface_index)) orelse continue;
                const surface_key = @intFromPtr(surface);
                const candidate_session = window.private().session_identity_index.sessionForAttachment(surface_key) orelse continue;
                if (candidate_session != route.session_id) continue;
                return .{
                    .window = window,
                    .workspace_page = workspace_page,
                    .runtime = runtime,
                    .leaf = leaf,
                    .surface = surface,
                    .route = route,
                };
            }
        }
    }

    return null;
}

fn selectWorkspaceControlPage(
    window: *Window,
    workspace_page: *WorkspacePage,
    focus_window: bool,
) void {
    const page = window.getTabView().getPage(workspace_page.as(gtk.Widget));
    window.getTabView().setSelectedPage(page);
    if (focus_window) {
        window.focusWorkspaceSelection(workspace_page);
        window.as(gtk.Window).present();
    }
}

fn parseWorkspaceControlWorkspaceRef(value: []const u8) ?workspace_ids.WorkspaceId {
    if (std.mem.startsWith(u8, value, "workspace:")) {
        const raw = std.fmt.parseInt(u64, value["workspace:".len..], 10) catch return null;
        if (raw == 0) return null;
        return workspace_ids.WorkspaceId.init(raw);
    }

    const parsed = workspace_ids.parse(value) catch return null;
    return switch (parsed) {
        .workspace => |workspace_id| workspace_id,
        else => null,
    };
}

fn parseWorkspaceControlSessionRef(value: []const u8) ?workspace_ids.SessionId {
    if (std.mem.startsWith(u8, value, "session:")) {
        const raw = std.fmt.parseInt(u64, value["session:".len..], 10) catch return null;
        if (raw == 0) return null;
        return workspace_ids.SessionId.init(raw);
    }

    const parsed = workspace_ids.parse(value) catch return null;
    return switch (parsed) {
        .session => |session_id| session_id,
        else => null,
    };
}

fn workspaceControlSplitDirection(
    direction: WorkspaceControlSplitDirection,
) SplitTabs.Tree.Split.Direction {
    return switch (direction) {
        .right => .right,
        .left => .left,
        .up => .up,
        .down => .down,
    };
}

fn allocWorkspaceControlCommand(
    alloc: std.mem.Allocator,
    command: WorkspaceControlCommand,
) !configpkg.Command {
    return switch (command) {
        .shell => |value| .{ .shell = try alloc.dupeZ(u8, value) },
        .argv => |argv| blk: {
            var owned: std.ArrayList([:0]const u8) = .empty;
            errdefer {
                for (owned.items) |item| alloc.free(item);
                owned.deinit(alloc);
            }

            for (argv) |item| {
                try owned.append(alloc, try alloc.dupeZ(u8, item));
            }

            break :blk .{ .direct = try owned.toOwnedSlice(alloc) };
        },
    };
}

fn workspaceModelCommandFromSurfaceAlloc(
    alloc: std.mem.Allocator,
    command: ?configpkg.Command,
) !workspace_model.Command {
    if (command) |owned| {
        return switch (owned) {
            .shell => |value| .{ .shell = try alloc.dupe(u8, value) },
            .direct => |argv| blk: {
                var copied: std.ArrayList([]const u8) = .empty;
                errdefer {
                    for (copied.items) |item| alloc.free(item);
                    copied.deinit(alloc);
                }
                for (argv) |item| {
                    try copied.append(alloc, try alloc.dupe(u8, item));
                }
                break :blk .{ .argv = try copied.toOwnedSlice(alloc) };
            },
        };
    }

    if (std.process.getEnvVarOwned(alloc, "SHELL")) |shell| {
        return .{ .shell = shell };
    } else |_| {}

    if (@import("builtin").os.tag == .windows) {
        return .{ .shell = try alloc.dupe(u8, "cmd.exe") };
    }

    const passwd = try internal_os.passwd.get(alloc);
    if (passwd.shell) |shell| {
        return .{ .shell = shell };
    }

    return .{ .shell = try alloc.dupe(u8, "sh") };
}

fn deinitWorkspaceControlCommand(
    alloc: std.mem.Allocator,
    command: *const configpkg.Command,
) void {
    switch (command.*) {
        .shell => |value| alloc.free(value),
        .direct => |argv| {
            for (argv) |item| alloc.free(item);
            alloc.free(argv);
        },
    }
}

fn testWorkspaceRuntime(
    alloc: std.mem.Allocator,
) !struct {
    registry: workspace_registry.Registry,
    workspace: *workspace_registry.WorkspaceRuntime,
} {
    var registry = workspace_registry.Registry.init(alloc);
    errdefer registry.deinit();

    const workspace = try registry.createWorkspace(
        "ghostty",
        "ghostty",
        "2026-03-24T00:00:00Z",
    );
    try workspace.windows.append(alloc, .{
        .window_id = workspace_ids.WindowId.init(1),
        .workspace_id = workspace.workspace.workspace_id,
        .is_active = true,
        .is_quick_terminal = false,
    });
    try workspace.splits.append(alloc, .{
        .split_id = workspace_ids.SplitId.init(11),
        .workspace_id = workspace.workspace.workspace_id,
        .window_id = workspace_ids.WindowId.init(1),
        .title = "Main Split",
        .ordinal = 0,
        .tab_ids = try workspace.runtimeAllocator().dupe(workspace_ids.TabId, &.{workspace_ids.TabId.init(21)}),
        .layout_root_id = "split-root-11",
    });
    try workspace.tabs.append(alloc, .{
        .tab_id = workspace_ids.TabId.init(21),
        .split_id = workspace_ids.SplitId.init(11),
        .workspace_id = workspace.workspace.workspace_id,
        .window_id = workspace_ids.WindowId.init(1),
        .title = "build",
        .title_override = "logs",
        .layout_root_id = "tab-root-21",
        .ordinal = 0,
        .needs_attention = true,
    });
    try workspace.sessions.append(alloc, .{
        .session_id = workspace_ids.SessionId.init(31),
        .workspace_id = workspace.workspace.workspace_id,
        .window_id = workspace_ids.WindowId.init(1),
        .tab_id = workspace_ids.TabId.init(21),
        .split_id = workspace_ids.SplitId.init(11),
        .layout_node_id = "session-leaf-31",
        .title = "shell",
        .title_override = "cargo test",
        .cwd = "/home/ignat/code/ghostty",
        .command = .{ .shell = "zsh" },
        .focus_state = .focused,
        .activity_state = .bell_pending,
    });
    workspace.workspace.split_ids = try workspace.runtimeAllocator().dupe(workspace_ids.SplitId, &.{workspace_ids.SplitId.init(11)});
    workspace.workspace.tab_ids = try workspace.runtimeAllocator().dupe(workspace_ids.TabId, &.{workspace_ids.TabId.init(21)});
    workspace.workspace.session_ids = try workspace.runtimeAllocator().dupe(workspace_ids.SessionId, &.{workspace_ids.SessionId.init(31)});
    workspace.workspace.selected_window_id = workspace_ids.WindowId.init(1);
    workspace.workspace.selected_split_id = workspace_ids.SplitId.init(11);
    workspace.workspace.selected_tab_id = workspace_ids.TabId.init(21);
    workspace.workspace.selected_session_id = workspace_ids.SessionId.init(31);

    return .{
        .registry = registry,
        .workspace = workspace,
    };
}

test "workspace sidebar subtitle includes session counts when needed" {
    const testing = std.testing;

    const subtitle = try WorkspaceSidebar.formatSidebarSubtitle(
        testing.allocator,
        "~/code/ghostty",
        .{
            .windows = 1,
            .splits = 2,
            .tabs = 2,
            .sessions = 6,
        },
    );
    defer testing.allocator.free(subtitle);

    try testing.expectEqualStrings("~/code/ghostty • 6 sessions", subtitle);
}

test "workspace sidebar subtitle stays plain for single-session workspaces" {
    const testing = std.testing;

    const subtitle = try WorkspaceSidebar.formatSidebarSubtitle(
        testing.allocator,
        "~/code/ghostty",
        .{
            .windows = 1,
            .splits = 1,
            .tabs = 1,
            .sessions = 1,
        },
    );
    defer testing.allocator.free(subtitle);

    try testing.expectEqualStrings("~/code/ghostty", subtitle);
}

test "workspace sidebar tooltip summarizes selected runtime session" {
    const testing = std.testing;

    var fixture = try testWorkspaceRuntime(testing.allocator);
    defer fixture.registry.deinit();

    const tooltip = (try WorkspaceSidebar.formatSidebarTooltip(
        testing.allocator,
        fixture.workspace,
    )).?;
    defer testing.allocator.free(tooltip);

    try testing.expect(std.mem.indexOf(u8, tooltip, "1 split • 1 session") != null);
    try testing.expect(std.mem.indexOf(u8, tooltip, "Selected split: Main Split") != null);
    try testing.expect(std.mem.indexOf(u8, tooltip, "Selected tab: logs") != null);
    try testing.expect(std.mem.indexOf(u8, tooltip, "Selected session: cargo test") != null);
    try testing.expect(std.mem.indexOf(u8, tooltip, "Working directory: /home/ignat/code/ghostty") != null);
}

test "saved workspace catalog lookup for runtime matches checkpoint path first" {
    const testing = std.testing;

    var fixture = try testWorkspaceRuntime(testing.allocator);
    defer fixture.registry.deinit();

    fixture.workspace.workspace.snapshot_ref = .{
        .snapshot_id = workspace_ids.SnapshotId.init(7),
        .saved_at = try testing.allocator.dupe(u8, "2026-04-06T10:00:00Z"),
        .path = try testing.allocator.dupe(u8, "work-restored.json"),
    };

    const entries = [_]workspace_snapshot.CatalogEntry{
        .{
            .snapshot_id = workspace_ids.SnapshotId.init(8),
            .workspace_id = fixture.workspace.workspace.workspace_id,
            .workspace_key = try testing.allocator.dupe(u8, "ghostty"),
            .workspace_name = try testing.allocator.dupe(u8, "ghostty"),
            .saved_at = try testing.allocator.dupe(u8, "2026-04-06T09:00:00Z"),
            .path = try testing.allocator.dupe(u8, "ghostty.json"),
        },
        .{
            .snapshot_id = workspace_ids.SnapshotId.init(7),
            .workspace_id = fixture.workspace.workspace.workspace_id,
            .workspace_key = try testing.allocator.dupe(u8, "work"),
            .workspace_name = try testing.allocator.dupe(u8, "work"),
            .saved_at = try testing.allocator.dupe(u8, "2026-04-06T10:00:00Z"),
            .path = try testing.allocator.dupe(u8, "work-restored.json"),
        },
    };
    defer for (entries) |entry| entry.deinit(testing.allocator);

    const matched = findSavedWorkspaceCatalogEntryForRuntime(
        entries[0..],
        fixture.workspace,
    ).?;

    try testing.expectEqualStrings("work-restored.json", matched.path);
    try testing.expectEqualStrings("work", matched.workspace_name);
}

test "saved scrollback restore path is validated" {
    const testing = std.testing;
    const valid_path = "ghostty-deadbeef.json.scrollback/snapshot-1/session-404.vt";

    try testing.expect(validWorkspaceScrollbackPath(valid_path));
    try testing.expect(!validWorkspaceScrollbackPath(""));
    try testing.expect(!validWorkspaceScrollbackPath("catalog.json"));
    try testing.expect(!validWorkspaceScrollbackPath("ghostty-deadbeef.json"));
    try testing.expect(!validWorkspaceScrollbackPath("/tmp/session-1.vt"));
    try testing.expect(!validWorkspaceScrollbackPath("ghostty-deadbeef.json.scrollback/../session-1.vt"));
    try testing.expect(!validWorkspaceScrollbackPath("ghostty-deadbeef.json.scrollback/snapshot-1/session-404.vt\x00truncated"));
}

test "saved scrollback autosave rewrites after restored generation changes" {
    const testing = std.testing;
    const restored_state: SavedScrollbackState = .{
        .generation = 0,
        .path = "ghostty-deadbeef.json.scrollback/snapshot-1/session-1.vt",
    };

    try testing.expect(!shouldWriteScrollbackGeneration(restored_state, 0));
    try testing.expect(shouldWriteScrollbackGeneration(restored_state, 1));
}

test "saved scrollback budget deferral preserves the prior generation" {
    const testing = std.testing;

    var fixture = try testWorkspaceRuntime(testing.allocator);
    defer fixture.registry.deinit();
    var snapshot_value = try workspace_snapshot.fromRuntimeAlloc(
        testing.allocator,
        workspace_ids.SnapshotId.init(2),
        "2026-07-10T00:00:00Z",
        fixture.workspace,
    );
    defer snapshot_value.deinit(testing.allocator);

    var generations: std.ArrayList(SavedScrollbackGeneration) = .empty;
    defer generations.deinit(testing.allocator);
    const checkpoint_path = "ghostty-deadbeef.json";
    const session_id = workspace_ids.SessionId.init(31);
    const prior_path = "ghostty-deadbeef.json.scrollback/snapshot-1/session-31.vt";

    try testing.expect(try preserveExistingScrollbackForDeferredSave(
        &snapshot_value,
        testing.allocator,
        &generations,
        .{
            .generation = 7,
            .path = prior_path,
        },
        true,
        checkpoint_path,
        session_id,
    ));
    try testing.expectEqualStrings(
        prior_path,
        snapshot_value.sessions[0].scrollback_path.?,
    );
    try testing.expectEqual(@as(usize, 1), generations.items.len);
    try testing.expectEqual(@as(u64, 7), generations.items[0].generation);
}

test "saved scrollback explicit save preserves unchanged existing sidecar" {
    const testing = std.testing;
    const checkpoint_path = "ghostty-deadbeef.json";
    const session_id = workspace_ids.SessionId.init(1);
    const restored_state: SavedScrollbackState = .{
        .generation = 0,
        .path = "ghostty-deadbeef.json.scrollback/snapshot-1/session-1.vt",
    };

    try testing.expect(!shouldWriteScrollbackForSave(
        .explicit,
        restored_state,
        true,
        session_id,
        checkpoint_path,
        0,
    ));
    try testing.expect(shouldWriteScrollbackForSave(
        .explicit,
        restored_state,
        true,
        session_id,
        checkpoint_path,
        1,
    ));
    try testing.expect(shouldWriteScrollbackForSave(
        .explicit,
        restored_state,
        false,
        session_id,
        checkpoint_path,
        0,
    ));
    try testing.expect(shouldWriteScrollbackForSave(
        .explicit,
        restored_state,
        true,
        session_id,
        "fork-deadbeef.json",
        0,
    ));
    try testing.expect(shouldWriteScrollbackForSave(
        .autosave,
        restored_state,
        true,
        session_id,
        "fork-deadbeef.json",
        0,
    ));
    try testing.expect(shouldWriteScrollbackForSave(
        .autosave,
        restored_state,
        true,
        workspace_ids.SessionId.init(2),
        checkpoint_path,
        0,
    ));
}

test "saved scrollback save copies unchanged restored sidecar for remapped session" {
    const testing = std.testing;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const storage = workspace_storage.Storage.init(testing.allocator, tmp.dir);
    const checkpoint_path = try storage.checkpointFilenameAlloc("ghostty");
    defer testing.allocator.free(checkpoint_path);
    const restored_path = try storage.scrollbackFilenameAlloc(
        checkpoint_path,
        workspace_ids.SnapshotId.init(1),
        workspace_ids.SessionId.init(43),
    );
    defer testing.allocator.free(restored_path);
    const live_path = try storage.scrollbackFilenameAlloc(
        checkpoint_path,
        workspace_ids.SnapshotId.init(2),
        workspace_ids.SessionId.init(99),
    );
    defer testing.allocator.free(live_path);

    try storage.ensureScrollbackDirForSnapshot(checkpoint_path, workspace_ids.SnapshotId.init(1));
    try storage.ensureScrollbackDirForSnapshot(checkpoint_path, workspace_ids.SnapshotId.init(2));
    {
        const file = try tmp.dir.createFile(restored_path, .{});
        defer file.close();
        try file.writeAll("saved restored bytes");
    }

    var dest_dir = try storage.openScrollbackDirForSnapshot(
        checkpoint_path,
        workspace_ids.SnapshotId.init(2),
    );
    defer dest_dir.close();

    const copied = try copyUnchangedScrollbackSidecarForSave(
        storage,
        .{
            .generation = 0,
            .path = restored_path,
        },
        true,
        checkpoint_path,
        0,
        dest_dir,
        std.fs.path.basename(live_path),
        termio.Termio.max_saved_scrollback_replay_bytes,
    );
    try testing.expectEqual(
        @as(?usize, "saved restored bytes".len),
        copied,
    );

    const data = try tmp.dir.readFileAlloc(testing.allocator, live_path, 1024);
    defer testing.allocator.free(data);
    try testing.expectEqualStrings("saved restored bytes", data);
}

test "saved scrollback fast path rejects oversized existing sidecar" {
    const testing = std.testing;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const storage = workspace_storage.Storage.init(testing.allocator, tmp.dir);
    const checkpoint_path = try storage.checkpointFilenameAlloc("ghostty");
    defer testing.allocator.free(checkpoint_path);
    const restored_path = try storage.scrollbackFilenameAlloc(
        checkpoint_path,
        workspace_ids.SnapshotId.init(1),
        workspace_ids.SessionId.init(43),
    );
    defer testing.allocator.free(restored_path);

    try storage.ensureScrollbackDirForSnapshot(checkpoint_path, workspace_ids.SnapshotId.init(1));
    {
        const file = try tmp.dir.createFile(restored_path, .{});
        defer file.close();
        try file.setEndPos(termio.Termio.max_saved_scrollback_replay_bytes + 1);
    }

    const usable = try scrollbackFileUsable(
        storage,
        restored_path,
        termio.Termio.max_saved_scrollback_replay_bytes,
    );
    try testing.expect(!usable);
    try testing.expect(shouldWriteScrollbackForSave(
        .autosave,
        .{
            .generation = 0,
            .path = restored_path,
        },
        false,
        workspace_ids.SessionId.init(43),
        checkpoint_path,
        0,
    ));
}

test "saved scrollback state prune drops sessions missing from live runtime" {
    const testing = std.testing;

    var states = std.AutoHashMap(workspace_ids.SessionId, SavedScrollbackState).init(testing.allocator);
    defer states.deinit();
    defer {
        var it = states.valueIterator();
        while (it.next()) |state| testing.allocator.free(state.path);
    }

    const live_session = workspace_ids.SessionId.init(1);
    const stale_session = workspace_ids.SessionId.init(2);
    try states.put(live_session, .{
        .generation = 1,
        .path = try testing.allocator.dupe(u8, "ghostty-deadbeef.json.scrollback/snapshot-1/session-1.vt"),
    });
    try states.put(stale_session, .{
        .generation = 1,
        .path = try testing.allocator.dupe(u8, "ghostty-deadbeef.json.scrollback/snapshot-1/session-2.vt"),
    });

    pruneSavedScrollbackStates(testing.allocator, &states, &.{live_session});

    try testing.expect(states.contains(live_session));
    try testing.expect(!states.contains(stale_session));
}

test "autosave scrollback budget divides the pass fairly" {
    const testing = std.testing;

    try testing.expectEqual(
        workspace_autosave_scrollback_session_bytes,
        AutosaveScrollbackBudget.init(1).per_session,
    );
    try testing.expectEqual(
        workspace_autosave_scrollback_session_bytes,
        AutosaveScrollbackBudget.init(2).per_session,
    );
    try testing.expectEqual(
        workspace_autosave_scrollback_total_bytes / 3,
        AutosaveScrollbackBudget.init(3).per_session,
    );
    try testing.expectEqual(
        workspace_autosave_scrollback_total_bytes,
        AutosaveScrollbackBudget.init(3).remaining,
    );
}
