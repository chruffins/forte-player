const std = @import("std");
const c = @import("c");
const File = @import("file.zig").File;

/// An Allegro configuration (INI-style key/value store).
pub const Config = struct {
    config: *c.ALLEGRO_CONFIG,

    pub fn create() Config {
        return .{ .config = c.al_create_config().? };
    }

    pub fn load(filename: [:0]const u8) ?Config {
        const cfg = c.al_load_config_file(filename.ptr);
        return if (cfg) |cc| Config{ .config = cc } else null;
    }

    pub fn loadFromFile(fp: *File) ?Config {
        const cfg = c.al_load_config_file_f(fp.file);
        return if (cfg) |cc| Config.fromCPtr(cc) else null;
    }

    /// Borrow a raw Allegro config pointer (advanced / interop).
    pub fn fromCPtr(ptr: *c.ALLEGRO_CONFIG) Config {
        return .{ .config = ptr };
    }

    pub fn destroy(self: *Config) void {
        c.al_destroy_config(self.config);
    }

    pub fn getValue(self: *const Config, section: [:0]const u8, key: [:0]const u8) ?[:0]const u8 {
        const v = c.al_get_config_value(self.config, section.ptr, key.ptr);
        return if (v == null) null else std.mem.span(v);
    }

    pub fn setValue(self: *Config, section: [:0]const u8, key: [:0]const u8, value: [:0]const u8) void {
        c.al_set_config_value(self.config, section.ptr, key.ptr, value.ptr);
    }

    pub fn addSection(self: *Config, name: [:0]const u8) void {
        c.al_add_config_section(self.config, name.ptr);
    }

    pub fn removeSection(self: *Config, section: [:0]const u8) bool {
        return c.al_remove_config_section(self.config, section.ptr);
    }

    pub fn removeKey(self: *Config, section: [:0]const u8, key: [:0]const u8) bool {
        return c.al_remove_config_key(self.config, section.ptr, key.ptr);
    }

    /// Insert a `#`-prefixed comment into the given section.
    pub fn addComment(self: *Config, section: [:0]const u8, comment: [:0]const u8) void {
        c.al_add_config_comment(self.config, section.ptr, comment.ptr);
    }

    /// Merge two configs into a brand new one (values in `b` win). Returns null on alloc failure.
    pub fn merge(a: *const Config, b: *const Config) ?Config {
        const merged = c.al_merge_config(a.config, b.config);
        return if (merged) |mc| Config{ .config = mc } else null;
    }

    /// Iterate the (key, value) pairs of a section. Values are owned by the config.
    pub fn entries(self: *const Config, section: [:0]const u8) EntryIter {
        var it: EntryIter = .{};
        it.first = c.al_get_first_config_entry(self.config, section.ptr, &it.iter);
        return it;
    }

    pub fn save(self: *const Config, filename: [:0]const u8) bool {
        return c.al_save_config_file(filename.ptr, self.config);
    }

    pub fn saveToFile(self: *const Config, fp: *File) bool {
        return c.al_save_config_file_f(fp.file, self.config);
    }

    pub fn mergeInto(self: *Config, other: *const Config) void {
        c.al_merge_config_into(self.config, other.config);
    }

    /// Iterate the names of all sections.
    pub fn sections(self: *const Config, allocator: std.mem.Allocator) ![][]const u8 {
        var list = std.ArrayList([]const u8).init(allocator);
        var iter: ?*c.ALLEGRO_CONFIG_SECTION = null;
        var name = c.al_get_first_config_section(self.config, &iter);
        while (name != null) : (name = c.al_get_next_config_section(&iter)) {
            try list.append(try allocator.dupe(u8, std.mem.span(name)));
        }
        return list.toOwnedSlice();
    }
};

pub const EntryIter = struct {
    first: [*c]const u8 = null,
    iter: ?*c.ALLEGRO_CONFIG_ENTRY = null,

    /// Returns the next key name, or null when exhausted.
    pub fn next(self: *EntryIter) ?[:0]const u8 {
        const key = if (self.first) |k| k else c.al_get_next_config_entry(&self.iter);
        self.first = null;
        return if (key == null) null else std.mem.span(key);
    }
};

test "refAllDecls" {
    std.testing.refAllDecls(Config);
    std.testing.refAllDecls(EntryIter);
}
