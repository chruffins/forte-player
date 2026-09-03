const std = @import("std");
const c = @import("c");
const Display = @import("display.zig").Display;
const EventSource = @import("events.zig").EventSource;

pub const Error = error{ InitFailed };

pub fn init() !void {
    if (!c.al_init_native_dialog_addon()) return Error.InitFailed;
}

pub fn shutdown() void {
    c.al_shutdown_native_dialog_addon();
}

pub fn initialized() bool {
    return c.al_is_native_dialog_addon_initialized();
}

pub fn version() u32 {
    return c.al_get_allegro_native_dialog_version();
}

/// File chooser modes.
pub const FileChooserMode = struct {
    pub const FILE_MUST_EXIST = c.ALLEGRO_FILECHOOSER_FILE_MUST_EXIST;
    pub const SAVE = c.ALLEGRO_FILECHOOSER_SAVE;
    pub const FOLDER = c.ALLEGRO_FILECHOOSER_FOLDER;
    pub const MULTIPLE = c.ALLEGRO_FILECHOOSER_MULTIPLE;
};

/// MessageBox button flags.
pub const MessageBox = struct {
    pub const OK = c.ALLEGRO_MESSAGEBOX_OK;
    pub const OK_CANCEL = c.ALLEGRO_MESSAGEBOX_OK_CANCEL;
    pub const YES_NO = c.ALLEGRO_MESSAGEBOX_YES_NO;
    pub const YES_NO_CANCEL = c.ALLEGRO_MESSAGEBOX_YES_NO_CANCEL;
};

/// A native file open/save dialog.
pub const FileDialog = struct {
    dialog: *c.ALLEGRO_FILECHOOSER,

    /// `patterns` is a pipe-separated list of patterns, e.g. "*.png;*.jpg" (semicolon-separated).
    pub fn create(initialPath: ?[:0]const u8, title: [:0]const u8, patterns: ?[:0]const u8, mode: i32) !FileDialog {
        const d = c.al_create_native_file_dialog(
            if (initialPath) |p| p.ptr else null,
            title.ptr,
            if (patterns) |p| p.ptr else null,
            mode,
        ) orelse return error.CreateFailed;
        return .{ .dialog = d };
    }

    /// Show the dialog (blocking). Returns true if the user selected a file.
    pub fn show(self: *FileDialog, parent: ?*Display) bool {
        return c.al_show_native_file_dialog(if (parent) |d| d.display else null, self.dialog);
    }

    pub fn count(self: *const FileDialog) i32 {
        return c.al_get_native_file_dialog_count(self.dialog);
    }

    pub fn path(self: *const FileDialog, index: usize) [:0]const u8 {
        return std.mem.span(c.al_get_native_file_dialog_path(self.dialog, index));
    }

    /// The first selected path, if any.
    pub fn firstPath(self: *const FileDialog) ?[:0]const u8 {
        if (self.count() < 1) return null;
        return self.path(0);
    }

    pub fn destroy(self: *FileDialog) void {
        c.al_destroy_native_file_dialog(self.dialog);
    }
};

/// Show a blocking native message box. Returns the id of the pressed button
/// (commonly ALLEGRO_MESSAGEBOX_BUTTON_YES / _NO).
pub fn messageBox(parent: ?*Display, title: [:0]const u8, heading: [:0]const u8, text: [:0]const u8, buttons: [:0]const u8, flags: i32) i32 {
    return c.al_show_native_message_box(if (parent) |d| d.display else null, title.ptr, heading.ptr, text.ptr, buttons.ptr, flags);
}

/// A native text log window (console-like).
pub const TextLog = struct {
    log: *c.ALLEGRO_TEXTLOG,

    pub fn open(title: [:0]const u8, flags: i32) !TextLog {
        const t = c.al_open_native_text_log(title.ptr, flags) orelse return error.CreateFailed;
        return .{ .log = t };
    }

    pub fn close(self: *TextLog) void {
        c.al_close_native_text_log(self.log);
    }

    pub fn append(self: *TextLog, format: [:0]const u8) void {
        c.al_append_native_text_log(self.log, format.ptr);
    }

    pub fn appendFormat(self: *TextLog, comptime fmt: [:0]const u8, args: anytype) void {
        var buf: [2048]u8 = undefined;
        const rendered = std.fmt.bufPrintZ(&buf, fmt, args) catch return;
        c.al_append_native_text_log(self.log, rendered.ptr);
    }

    pub fn eventSource(self: *TextLog) EventSource {
        return .{ .source = c.al_get_native_text_log_event_source(self.log) };
    }
};

test "refAllDecls" {
    std.testing.refAllDecls(FileDialog);
    std.testing.refAllDecls(TextLog);
}