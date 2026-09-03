const std = @import("std");
const c = @import("c");
const EventSource = @import("events.zig").EventSource;
const Display = @import("display.zig").Display;

/// Native menu item / menu flags.
pub const MenuFlags = struct {
    pub const DISABLED = c.ALLEGRO_MENU_ITEM_DISABLED;
    pub const CHECKED = c.ALLEGRO_MENU_ITEM_CHECKED;
    pub const CHECKBOX = c.ALLEGRO_MENU_ITEM_CHECKBOX;
};

/// A native menu bar or popup menu.
pub const Menu = struct {
    menu: *c.ALLEGRO_MENU,

    pub fn create() !Menu {
        const m = c.al_create_menu() orelse return error.CreateFailed;
        return .{ .menu = m };
    }

    pub fn createPopupMenu() !Menu {
        const m = c.al_create_popup_menu() orelse return error.CreateFailed;
        return .{ .menu = m };
    }

    pub fn destroy(self: *Menu) void {
        c.al_destroy_menu(self.menu);
    }

    pub fn clone(self: *const Menu) !Menu {
        const m = c.al_clone_menu(self.menu) orelse return error.CreateFailed;
        return .{ .menu = m };
    }

    pub fn cloneForPopup(self: *const Menu) !Menu {
        const m = c.al_clone_menu_for_popup(self.menu) orelse return error.CreateFailed;
        return .{ .menu = m };
    }

    /// Append an item. Returns its position, or -1 on failure.
    pub fn appendItem(self: *Menu, title: [:0]const u8, id: u16, flags: i32, icon: ?*c.ALLEGRO_BITMAP, submenu: ?*Menu) i32 {
        return c.al_append_menu_item(self.menu, title.ptr, id, flags, icon, if (submenu) |sm| sm.menu else null);
    }

    pub fn insertItem(self: *Menu, pos: i32, title: [:0]const u8, id: u16, flags: i32, icon: ?*c.ALLEGRO_BITMAP, submenu: ?*Menu) i32 {
        return c.al_insert_menu_item(self.menu, pos, title.ptr, id, flags, icon, if (submenu) |sm| sm.menu else null);
    }

    pub fn removeItem(self: *Menu, pos: i32) bool {
        return c.al_remove_menu_item(self.menu, pos);
    }

    pub fn find(self: *Menu, id: u16) ?Menu {
        const m = c.al_find_menu(self.menu, id);
        return if (m) |ptr| Menu{ .menu = ptr } else null;
    }

    pub fn findItem(self: *Menu, id: u16) ?struct { menu: Menu, index: i32 } {
        var menu: ?*c.ALLEGRO_MENU = null;
        var index: i32 = 0;
        if (!c.al_find_menu_item(self.menu, id, &menu, &index)) return null;
        return .{ .menu = .{ .menu = menu.? }, .index = index };
    }

    // -- Item inspection / editing --

    pub fn itemCaption(self: *Menu, pos: i32) [:0]const u8 {
        return std.mem.span(c.al_get_menu_item_caption(self.menu, pos));
    }

    pub fn setItemCaption(self: *Menu, pos: i32, caption: [:0]const u8) void {
        c.al_set_menu_item_caption(self.menu, pos, caption.ptr);
    }

    pub fn itemFlags(self: *Menu, pos: i32) i32 {
        return c.al_get_menu_item_flags(self.menu, pos);
    }

    pub fn setItemFlags(self: *Menu, pos: i32, flags: i32) void {
        c.al_set_menu_item_flags(self.menu, pos, flags);
    }

    pub fn itemIcon(self: *Menu, pos: i32) ?*c.ALLEGRO_BITMAP {
        return c.al_get_menu_item_icon(self.menu, pos);
    }

    pub fn setItemIcon(self: *Menu, pos: i32, icon: ?*c.ALLEGRO_BITMAP) void {
        c.al_set_menu_item_icon(self.menu, pos, icon);
    }

    // -- Event source / display mounting --

    pub fn enableEventSource(self: *Menu) EventSource {
        return .{ .source = c.al_enable_menu_event_source(self.menu) };
    }

    pub fn disableEventSource(self: *Menu) void {
        c.al_disable_menu_event_source(self.menu);
    }

    pub fn attachToDisplay(self: *Menu, display: *Display) bool {
        return c.al_set_display_menu(display.display, self.menu);
    }

    pub fn popup(self: *Menu, display: *Display) bool {
        return c.al_popup_menu(self.menu, display.display);
    }
};

pub fn defaultMenuEventSource() EventSource {
    return .{ .source = c.al_get_default_menu_event_source() };
}

/// Build a menu from an array of menu-info entries (used for menus declared as data).
pub fn build(info: []const c.ALLEGRO_MENU_INFO) ?Menu {
    const m = c.al_build_menu(info.ptr);
    return if (m) |ptr| Menu{ .menu = ptr } else null;
}

/// The menu currently attached to a display, if any.
pub fn getDisplayMenu(display: *Display) ?Menu {
    const m = c.al_get_display_menu(display.display);
    return if (m) |ptr| Menu{ .menu = ptr } else null;
}

pub fn removeDisplayMenu(display: *Display) ?Menu {
    const m = c.al_remove_display_menu(display.display);
    return if (m) |ptr| Menu{ .menu = ptr } else null;
}

test "refAllDecls" {
    std.testing.refAllDecls(Menu);
}
