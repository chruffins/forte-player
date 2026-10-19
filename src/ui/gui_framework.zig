//! Small, pure GUI primitives corresponding to the useful parts of the old
//! C++ drawable framework. These are models and geometry, not retained
//! Allegro objects: renderers consume their results and the application maps
//! returned target ids to semantic actions.

const std = @import("std");
const ui = @import("ui.zig");

pub const HorizontalAlignment = enum { left, center, right };
pub const VerticalAlignment = enum { top, center, bottom };
pub const ImageScaleMode = enum { stretch, fit, fill, none };

/// Destination placement for an image. For `fill`, the returned rectangle can
/// extend beyond `box`; the renderer should clip it to the box.
pub fn imagePlacement(source_width: f32, source_height: f32, box: ui.Rect, mode: ImageScaleMode, horizontal: HorizontalAlignment, vertical: VerticalAlignment) ui.Rect {
    if (source_width <= 0 or source_height <= 0) return .{};
    if (mode == .stretch) return box;
    if (mode == .none) {
        return alignedRect(box, source_width, source_height, horizontal, vertical);
    }
    const width_scale = box.w / source_width;
    const height_scale = box.h / source_height;
    const scale = if (mode == .fit) @min(width_scale, height_scale) else @max(width_scale, height_scale);
    return alignedRect(box, source_width * scale, source_height * scale, horizontal, vertical);
}

fn alignedRect(box: ui.Rect, width: f32, height: f32, horizontal: HorizontalAlignment, vertical: VerticalAlignment) ui.Rect {
    const x = switch (horizontal) {
        .left => box.x,
        .center => box.x + (box.w - width) / 2,
        .right => box.right() - width,
    };
    const y = switch (vertical) {
        .top => box.y,
        .center => box.y + (box.h - height) / 2,
        .bottom => box.bottom() - height,
    };
    return .{ .x = x, .y = y, .w = width, .h = height };
}

pub const ButtonModel = struct {
    enabled: bool = true,
    interaction: Interaction = .{},

    pub fn visualState(self: ButtonModel) enum { disabled, normal, hovered, pressed, focused } {
        if (!self.enabled) return .disabled;
        if (self.interaction.pressed) return .pressed;
        if (self.interaction.hovered) return .hovered;
        if (self.interaction.focused) return .focused;
        return .normal;
    }
};

/// Normalized coordinates plus a pixel adjustment, matching the C++ UV type.
pub const Uv = struct {
    u: f32 = 0,
    v: f32 = 0,
    px_x: f32 = 0,
    px_y: f32 = 0,

    pub fn resolve(self: Uv, width: f32, height: f32) struct { x: f32, y: f32 } {
        return .{ .x = self.u * width + self.px_x, .y = self.v * height + self.px_y };
    }
};

pub const WidgetSpec = struct {
    position: Uv = .{},
    size: Uv = .{ .u = 1, .v = 1 },
    visible: bool = true,
    enabled: bool = true,
    focusable: bool = false,
    /// Parent viewport in pixel space. Off-screen widgets cannot receive input.
    clip: ?ui.Rect = null,

    pub fn bounds(self: WidgetSpec, width: f32, height: f32) ui.Rect {
        const pos = self.position.resolve(width, height);
        const size = self.size.resolve(width, height);
        return .{ .x = pos.x, .y = pos.y, .w = size.x, .h = size.y };
    }

    pub fn hitTest(self: WidgetSpec, width: f32, height: f32, x: f32, y: f32) bool {
        if (!self.visible or !self.enabled) return false;
        if (self.clip) |clip| if (!containsPoint(clip, x, y)) return false;
        return containsPoint(self.bounds(width, height), x, y);
    }
};

pub const Interaction = struct {
    hovered: bool = false,
    pressed: bool = false,
    focused: bool = false,
};

pub const ScrollModel = struct {
    offset: f32 = 0,
    content_height: f32 = 0,
    viewport_height: f32 = 0,
    step: f32 = 24,

    pub fn maxOffset(self: ScrollModel) f32 {
        return @max(0, self.content_height - self.viewport_height);
    }

    pub fn setOffset(self: *ScrollModel, value: f32) void {
        self.offset = @max(0, @min(value, self.maxOffset()));
    }

    pub fn scrollBy(self: *ScrollModel, delta: f32) void {
        self.setOffset(self.offset + delta);
    }

    pub fn scrollWheel(self: *ScrollModel, notches: f32) void {
        self.scrollBy(notches * self.step);
    }

    pub fn page(self: *ScrollModel, direction: f32) void {
        self.scrollBy(direction * @max(1, self.viewport_height - self.step));
    }

    pub fn thumb(self: ScrollModel, viewport: ui.Rect, width: f32) ?ui.Rect {
        if (self.content_height <= self.viewport_height or self.viewport_height <= 0) return null;
        const track_height = viewport.h;
        const thumb_height = @max(18, track_height * self.viewport_height / self.content_height);
        const travel = @max(0, track_height - thumb_height);
        const y = viewport.y + travel * self.offset / self.maxOffset();
        return .{ .x = viewport.right() - width, .y = y, .w = width, .h = thumb_height };
    }
};

pub const SliderModel = struct {
    value: f32 = 0,
    min: f32 = 0,
    max: f32 = 1,

    pub fn normalized(self: SliderModel) f32 {
        if (self.max <= self.min) return 0;
        return @max(0, @min(1, (self.value - self.min) / (self.max - self.min)));
    }

    pub fn setNormalized(self: *SliderModel, fraction: f32) void {
        const f = @max(0, @min(1, fraction));
        self.value = self.min + (self.max - self.min) * f;
    }

    pub fn valueAt(self: SliderModel, track: ui.Rect, x: f32) f32 {
        if (track.w <= 0) return self.min;
        var copy = self;
        copy.setNormalized((x - track.x) / track.w);
        return copy.value;
    }

    pub fn thumbCenter(self: SliderModel, track: ui.Rect) f32 {
        return track.x + track.w * self.normalized();
    }
};

pub const TextLayout = struct {
    horizontal: HorizontalAlignment = .left,
    vertical: VerticalAlignment = .top,
    multiline: bool = false,
    line_height: f32 = 0,

    pub fn origin(self: TextLayout, box: ui.Rect, text_width: f32, text_height: f32) struct { x: f32, y: f32 } {
        const x = switch (self.horizontal) {
            .left => box.x,
            .center => box.x + (box.w - text_width) / 2,
            .right => box.right() - text_width,
        };
        const y = switch (self.vertical) {
            .top => box.y,
            .center => box.y + (box.h - text_height) / 2,
            .bottom => box.bottom() - text_height,
        };
        return .{ .x = x, .y = y };
    }
};

pub const TextInput = struct {
    storage: [512]u8 = undefined,
    len: usize = 0,
    cursor: usize = 0,
    truncated: bool = false,

    pub fn text(self: *const TextInput) []const u8 {
        return self.storage[0..self.len];
    }

    pub fn setText(self: *TextInput, value: []const u8) void {
        self.len = @min(value.len, self.storage.len);
        while (self.len > 0 and !std.unicode.utf8ValidateSlice(value[0..self.len])) self.len -= 1;
        self.truncated = self.len < value.len;
        @memcpy(self.storage[0..self.len], value[0..self.len]);
        self.cursor = self.len;
    }

    pub fn insertCodepoint(self: *TextInput, codepoint: u32) bool {
        if (codepoint < 0x20 or codepoint == 0x7f or codepoint > 0x10ffff) return false;
        var encoded: [4]u8 = undefined;
        const width = std.unicode.utf8Encode(@intCast(codepoint), &encoded) catch return false;
        if (self.len + width > self.storage.len) return false;
        @memmove(self.storage[self.cursor + width .. self.len + width], self.storage[self.cursor..self.len]);
        @memcpy(self.storage[self.cursor .. self.cursor + width], encoded[0..width]);
        self.len += width;
        self.cursor += width;
        return true;
    }

    pub fn backspace(self: *TextInput) bool {
        if (self.cursor == 0) return false;
        const start = previousBoundary(self.storage[0..self.len], self.cursor);
        @memmove(self.storage[start .. self.len - (self.cursor - start)], self.storage[self.cursor..self.len]);
        self.len -= self.cursor - start;
        self.cursor = start;
        if (self.len == 0) self.truncated = false;
        return true;
    }

    pub fn deleteForward(self: *TextInput) bool {
        if (self.cursor >= self.len) return false;
        const end_pos = nextBoundary(self.storage[0..self.len], self.cursor);
        @memmove(self.storage[self.cursor .. self.len - (end_pos - self.cursor)], self.storage[end_pos..self.len]);
        self.len -= end_pos - self.cursor;
        if (self.len == 0) self.truncated = false;
        return true;
    }

    pub fn moveLeft(self: *TextInput) void {
        self.cursor = previousBoundary(self.storage[0..self.len], self.cursor);
    }

    pub fn moveRight(self: *TextInput) void {
        self.cursor = nextBoundary(self.storage[0..self.len], self.cursor);
    }

    pub fn home(self: *TextInput) void {
        self.cursor = 0;
    }
    pub fn end(self: *TextInput) void {
        self.cursor = self.len;
    }

    /// Approximate a mouse cursor position without font dependencies. The GUI
    /// renderer can replace this with measured glyph widths when it has a font
    /// handle; this fallback still provides predictable click-to-edit behavior.
    pub fn setCursorFraction(self: *TextInput, fraction: f32) void {
        const target = @as(usize, @intFromFloat(@max(0, @min(1, fraction)) * @as(f32, @floatFromInt(glyphCount(self.text())))));
        var index: usize = 0;
        var glyph: usize = 0;
        while (index < self.len and glyph < target) : (glyph += 1) index = nextBoundary(self.storage[0..self.len], index);
        self.cursor = index;
    }
};

fn previousBoundary(text: []const u8, index: usize) usize {
    var result = @min(index, text.len);
    if (result > 0) result -= 1;
    while (result > 0 and isUtf8Continuation(text[result])) result -= 1;
    return result;
}

fn nextBoundary(text: []const u8, index: usize) usize {
    var result = @min(index + 1, text.len);
    while (result < text.len and isUtf8Continuation(text[result])) result += 1;
    return result;
}

pub fn isUtf8Continuation(byte: u8) bool {
    return (byte & 0xc0) == 0x80;
}

pub fn glyphCount(text: []const u8) usize {
    var count: usize = 0;
    for (text) |byte| {
        if (!isUtf8Continuation(byte)) count += 1;
    }
    return count;
}

/// Return a valid UTF-8 prefix containing at most `max_glyphs` glyphs.
pub fn truncate(text: []const u8, max_glyphs: usize) []const u8 {
    if (max_glyphs == 0) return "";
    var glyphs: usize = 0;
    var index: usize = 0;
    while (index < text.len and glyphs < max_glyphs) : (glyphs += 1) {
        index += 1;
        while (index < text.len and isUtf8Continuation(text[index])) index += 1;
    }
    return text[0..index];
}

pub const Event = union(enum) {
    mouse_move: struct { x: f32, y: f32 },
    mouse_down: struct { x: f32, y: f32, button: u8 },
    mouse_up: struct { x: f32, y: f32, button: u8 },
    wheel: struct { x: f32, y: f32, delta: f32 },
    focus_next,
    focus_previous,
    cancel,
};

pub const EventResult = struct {
    handled: bool = false,
    target: ?u16 = null,
    activated: bool = false,
};

/// Deterministic hit routing with top-most-wins ordering, pointer capture for
/// press/release, hover tracking, and keyboard focus traversal. Targets are
/// value records; no callbacks or ownership are hidden in the framework.
pub const Dispatcher = struct {
    targets: [64]Target = undefined,
    count: usize = 0,
    hovered: ?u16 = null,
    pressed: ?u16 = null,
    focused: ?u16 = null,

    pub const Target = struct { id: u16, spec: WidgetSpec };

    pub fn add(self: *Dispatcher, id: u16, spec: WidgetSpec) bool {
        if (self.count >= self.targets.len) return false;
        self.targets[self.count] = .{ .id = id, .spec = spec };
        self.count += 1;
        return true;
    }

    pub fn clear(self: *Dispatcher) void {
        self.count = 0;
        self.hovered = null;
        self.pressed = null;
        self.focused = null;
    }

    fn targetAt(self: *const Dispatcher, width: f32, height: f32, x: f32, y: f32) ?Target {
        var i = self.count;
        while (i > 0) {
            i -= 1;
            const target = self.targets[i];
            if (target.spec.hitTest(width, height, x, y)) return target;
        }
        return null;
    }

    pub fn dispatch(self: *Dispatcher, event: Event, width: f32, height: f32) EventResult {
        switch (event) {
            .mouse_move => |mouse| {
                const target = self.targetAt(width, height, mouse.x, mouse.y);
                self.hovered = if (target) |t| t.id else null;
                return .{ .handled = target != null or self.pressed != null, .target = self.pressed orelse self.hovered };
            },
            .mouse_down => |mouse| {
                if (mouse.button != 1) return .{};
                const target = self.targetAt(width, height, mouse.x, mouse.y) orelse return .{};
                self.pressed = target.id;
                if (target.spec.focusable) self.focused = target.id;
                return .{ .handled = true, .target = target.id };
            },
            .mouse_up => |mouse| {
                if (mouse.button != 1) return .{};
                const target = self.targetAt(width, height, mouse.x, mouse.y);
                const pressed = self.pressed;
                self.pressed = null;
                return .{ .handled = target != null or pressed != null, .target = if (target) |t| t.id else pressed, .activated = target != null and pressed != null and target.?.id == pressed.? };
            },
            .wheel => |wheel| {
                const target = self.targetAt(width, height, wheel.x, wheel.y) orelse return .{};
                return .{ .handled = true, .target = target.id };
            },
            .focus_next, .focus_previous => {
                if (self.count == 0) return .{};
                const forward = event == .focus_next;
                var start: usize = if (forward) 0 else self.count - 1;
                if (self.focused) |id| {
                    for (self.targets[0..self.count], 0..) |target, index| {
                        if (target.id == id) {
                            start = if (forward) (index + 1) % self.count else (index + self.count - 1) % self.count;
                            break;
                        }
                    }
                }
                var attempts: usize = 0;
                while (attempts < self.count) : (attempts += 1) {
                    if (self.targets[start].spec.visible and self.targets[start].spec.enabled and self.targets[start].spec.focusable) {
                        self.focused = self.targets[start].id;
                        return .{ .handled = true, .target = self.focused };
                    }
                    if (forward) start = (start + 1) % self.count else start = if (start == 0) self.count - 1 else start - 1;
                }
                return .{};
            },
            .cancel => {
                self.pressed = null;
                self.hovered = null;
                return .{};
            },
        }
    }
};

/// Half-open bounds reject zero-sized controls and shared-edge double hits.
pub fn containsPoint(r: ui.Rect, x: f32, y: f32) bool {
    return r.w > 0 and r.h > 0 and x >= r.x and y >= r.y and x < r.right() and y < r.bottom();
}

test "image placement preserves aspect ratio and alignment" {
    const box = ui.Rect{ .x = 10, .y = 20, .w = 300, .h = 200 };
    const fit = imagePlacement(100, 100, box, .fit, .center, .center);
    try std.testing.expectEqual(@as(f32, 200), fit.w);
    try std.testing.expectEqual(@as(f32, 200), fit.h);
    try std.testing.expectEqual(@as(f32, 60), fit.x);
    try std.testing.expectEqual(@as(f32, 20), fit.y);
    const fill = imagePlacement(100, 50, box, .fill, .center, .center);
    try std.testing.expectEqual(@as(f32, 400), fill.w);
    try std.testing.expectEqual(@as(f32, 200), fill.h);
    try std.testing.expectEqual(@as(f32, -40), fill.x);
}

test "button model prioritizes disabled and pressed visuals" {
    var button = ButtonModel{ .interaction = .{ .hovered = true } };
    try std.testing.expectEqual(ButtonModel.visualState(button), .hovered);
    button.interaction.pressed = true;
    try std.testing.expectEqual(ButtonModel.visualState(button), .pressed);
    button.enabled = false;
    try std.testing.expectEqual(ButtonModel.visualState(button), .disabled);
}

test "text input edits Unicode at codepoint boundaries" {
    var input = TextInput{};
    input.setText("ab");
    input.moveLeft();
    try std.testing.expect(input.insertCodepoint('€'));
    try std.testing.expectEqualStrings("a€b", input.text());
    try std.testing.expect(input.backspace());
    try std.testing.expectEqualStrings("ab", input.text());
    input.home();
    try std.testing.expect(input.deleteForward());
    try std.testing.expectEqualStrings("b", input.text());

    var long: [512]u8 = @splat('a');
    long[510] = 0xe2;
    long[511] = 0x82;
    input.setText(&long);
    try std.testing.expectEqual(@as(usize, 510), input.text().len);
    try std.testing.expect(input.truncated);
    try std.testing.expect(std.unicode.utf8ValidateSlice(input.text()));
    while (input.backspace()) {}
    try std.testing.expect(!input.truncated);
}

test "UV resolves normalized plus pixel coordinates" {
    const p = (Uv{ .u = 0.25, .v = 0.5, .px_x = 8, .px_y = -4 }).resolve(800, 600);
    try std.testing.expectEqual(@as(f32, 208), p.x);
    try std.testing.expectEqual(@as(f32, 296), p.y);
}

test "scroll model clamps and computes a thumb" {
    var model = ScrollModel{ .content_height = 1000, .viewport_height = 200 };
    model.scrollBy(900);
    try std.testing.expectEqual(@as(f32, 800), model.offset);
    const thumb = model.thumb(.{ .x = 0, .y = 0, .w = 100, .h = 200 }, 6) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(f32, 40), thumb.h);
    try std.testing.expectEqual(@as(f32, 160), thumb.y);
}

test "slider clamps pointer values" {
    var slider = SliderModel{ .value = 0.5, .min = 0, .max = 100 };
    slider.setNormalized(2);
    try std.testing.expectEqual(@as(f32, 100), slider.value);
    try std.testing.expectEqual(@as(f32, 25), (SliderModel{ .min = 0, .max = 100 }).valueAt(.{ .x = 10, .w = 100 }, 35));
}

test "dispatcher captures a click and traverses focus" {
    var dispatcher = Dispatcher{};
    try std.testing.expect(dispatcher.add(1, .{ .position = .{ .px_x = 10, .px_y = 10 }, .size = .{ .px_x = 100, .px_y = 40 }, .focusable = true }));
    try std.testing.expect(dispatcher.add(2, .{ .position = .{ .px_x = 10, .px_y = 10 }, .size = .{ .px_x = 100, .px_y = 40 } }));
    _ = dispatcher.dispatch(.{ .mouse_down = .{ .x = 20, .y = 20, .button = 1 } }, 800, 600);
    const result = dispatcher.dispatch(.{ .mouse_up = .{ .x = 20, .y = 20, .button = 1 } }, 800, 600);
    try std.testing.expect(result.activated);
    const focus = dispatcher.dispatch(.focus_next, 800, 600);
    try std.testing.expectEqual(@as(?u16, 1), focus.target);
}
