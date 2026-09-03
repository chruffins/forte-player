const std = @import("std");
const c = @import("c");

/// A mutable Unicode (UTF-8) string.
pub const String = struct {
    us: *c.ALLEGRO_USTR,

    pub fn new(s: [:0]const u8) !String {
        const us = c.al_ustr_new(s.ptr) orelse return error.AllocFailed;
        return .{ .us = us };
    }

    pub fn newFromBuffer(s: []const u8) !String {
        const us = c.al_ustr_new_from_buffer(s.ptr, s.len) orelse return error.AllocFailed;
        return .{ .us = us };
    }

    pub fn newFromUtf16(s: []const u16) !String {
        const us = c.al_ustr_new_from_utf16(s.ptr) orelse return error.AllocFailed;
        return .{ .us = us };
    }

    pub fn emptyString() *const c.ALLEGRO_USTR {
        return c.al_ustr_empty_string();
    }

    pub fn fromCPtr(ptr: *c.ALLEGRO_USTR) String {
        return .{ .us = ptr };
    }

    pub fn destroy(self: *String) void {
        c.al_ustr_free(self.us);
    }

    pub fn dup(self: *const String) !String {
        const us = c.al_ustr_dup(self.us) orelse return error.AllocFailed;
        return .{ .us = us };
    }

    pub fn dupSubstr(self: *const String, start: i32, end: i32) !String {
        const us = c.al_ustr_dup_substr(self.us, start, end) orelse return error.AllocFailed;
        return .{ .us = us };
    }

    /// Length in Unicode code points.
    pub fn length(self: *const String) usize {
        return c.al_ustr_length(self.us);
    }

    /// Length in bytes.
    pub fn size(self: *const String) usize {
        return c.al_ustr_size(self.us);
    }

    pub fn toCStr(self: *const String) [:0]const u8 {
        return std.mem.span(c.al_cstr(self.us));
    }

    /// Copy the NUL-terminated contents into a freshly allocated, owned buffer.
    /// Caller must free with `std.heap.page_allocator.free`.
    pub fn dupeCStr(self: *const String, allocator: std.mem.Allocator) ![:0]u8 {
        const raw = c.al_cstr_dup(self.us) orelse return error.AllocFailed;
        const slice = std.mem.span(raw);
        const buf = try allocator.dupeZ(u8, slice);
        c.al_free(raw);
        return buf;
    }

    /// Copy the NUL-terminated contents into `buf`.
    pub fn toBuffer(self: *const String, buf: []u8) void {
        c.al_ustr_to_buffer(self.us, buf.ptr, @intCast(buf.len));
    }

    // -- Codepoint access --

    pub fn get(self: *const String, pos: i32) i32 {
        return c.al_ustr_get(self.us, pos);
    }

    pub fn getAt(self: *const String, index: i32) i32 {
        const pos = c.al_ustr_offset(self.us, index);
        return c.al_ustr_get(self.us, pos);
    }

    pub fn set(self: *String, pos: i32, codepoint: i32) usize {
        return c.al_ustr_set_chr(self.us, pos, codepoint);
    }

    /// Advance `*pos` to the next codepoint; returns false at end.
    pub fn next(self: *const String, pos: *i32) bool {
        return c.al_ustr_next(self.us, pos);
    }

    pub fn prev(self: *const String, pos: *i32) bool {
        return c.al_ustr_prev(self.us, pos);
    }

    pub fn getNext(self: *const String, pos: *i32) i32 {
        return c.al_ustr_get_next(self.us, pos);
    }

    pub fn offset(self: *const String, index: i32) i32 {
        return c.al_ustr_offset(self.us, index);
    }

    // -- Editing --

    pub fn append(self: *String, other: *const String) bool {
        return c.al_ustr_append(self.us, other.us);
    }

    pub fn appendCStr(self: *String, s: [:0]const u8) bool {
        return c.al_ustr_append_cstr(self.us, s.ptr);
    }

    pub fn appendChar(self: *String, codepoint: i32) usize {
        return c.al_ustr_append_chr(self.us, codepoint);
    }

    pub fn appendFormat(self: *String, comptime fmt: [:0]const u8, args: anytype) bool {
        var buf: [4096]u8 = undefined;
        const rendered = std.fmt.bufPrintZ(&buf, fmt, args) catch return false;
        return c.al_ustr_append_cstr(self.us, rendered.ptr);
    }

    pub fn assign(self: *String, other: *const String) bool {
        return c.al_ustr_assign(self.us, other.us);
    }

    pub fn assignCStr(self: *String, s: [:0]const u8) bool {
        return c.al_ustr_assign_cstr(self.us, s.ptr);
    }

    pub fn insertChar(self: *String, pos: i32, codepoint: i32) usize {
        return c.al_ustr_insert_chr(self.us, pos, codepoint);
    }

    pub fn insertCStr(self: *String, pos: i32, s: [:0]const u8) bool {
        return c.al_ustr_insert_cstr(self.us, pos, s.ptr);
    }

    pub fn insert(self: *String, pos: i32, other: *const String) bool {
        return c.al_ustr_insert(self.us, pos, other.us);
    }

    pub fn removeChar(self: *String, pos: i32) bool {
        return c.al_ustr_remove_chr(self.us, pos);
    }

    pub fn removeRange(self: *String, start: i32, end: i32) bool {
        return c.al_ustr_remove_range(self.us, start, end);
    }

    pub fn truncate(self: *String, start: i32) bool {
        return c.al_ustr_truncate(self.us, start);
    }

    pub fn replaceRange(self: *String, start: i32, end: i32, other: *const String) bool {
        return c.al_ustr_replace_range(self.us, start, end, other.us);
    }

    // -- Search --

    pub fn find(self: *const String, start: i32, needle: *const String) i32 {
        return c.al_ustr_find_str(self.us, start, needle.us);
    }

    pub fn findCStr(self: *const String, start: i32, needle: [:0]const u8) i32 {
        return c.al_ustr_find_cstr(self.us, start, needle.ptr);
    }

    pub fn findChar(self: *const String, start: i32, codepoint: i32) i32 {
        return c.al_ustr_find_chr(self.us, start, codepoint);
    }

    pub fn rfindChar(self: *const String, start: i32, codepoint: i32) i32 {
        return c.al_ustr_rfind_chr(self.us, start, codepoint);
    }

    pub fn rfindCStr(self: *const String, start: i32, needle: [:0]const u8) i32 {
        return c.al_ustr_rfind_cstr(self.us, start, needle.ptr);
    }

    pub fn findReplaceCStr(self: *String, start: i32, findStr: [:0]const u8, replace: [:0]const u8) bool {
        return c.al_ustr_find_replace_cstr(self.us, start, findStr.ptr, replace.ptr);
    }

    pub fn hasPrefix(self: *const String, prefix: *const String) bool {
        return c.al_ustr_has_prefix(self.us, prefix.us);
    }

    pub fn hasPrefixCStr(self: *const String, prefix: [:0]const u8) bool {
        return c.al_ustr_has_prefix_cstr(self.us, prefix.ptr);
    }

    pub fn hasSuffixCStr(self: *const String, suffix: [:0]const u8) bool {
        return c.al_ustr_has_suffix_cstr(self.us, suffix.ptr);
    }

    pub fn trimWhitespace(self: *String) bool {
        return c.al_ustr_trim_ws(self.us);
    }

    pub fn ltrimWhitespace(self: *String) bool {
        return c.al_ustr_ltrim_ws(self.us);
    }

    pub fn rtrimWhitespace(self: *String) bool {
        return c.al_ustr_rtrim_ws(self.us);
    }

    pub fn hasSuffix(self: *const String, suffix: *const String) bool {
        return c.al_ustr_has_suffix(self.us, suffix.us);
    }

    pub fn prevGet(self: *const String, pos: *i32) i32 {
        return c.al_ustr_prev_get(self.us, pos);
    }

    pub fn rfindStr(self: *const String, start: i32, needle: *const String) i32 {
        return c.al_ustr_rfind_str(self.us, start, needle.us);
    }

    pub fn findSet(self: *const String, start: i32, accept: *const String) i32 {
        return c.al_ustr_find_set(self.us, start, accept.us);
    }

    pub fn findSetCStr(self: *const String, start: i32, accept: [:0]const u8) i32 {
        return c.al_ustr_find_set_cstr(self.us, start, accept.ptr);
    }

    pub fn findCSet(self: *const String, start: i32, reject: *const String) i32 {
        return c.al_ustr_find_cset(self.us, start, reject.us);
    }

    pub fn findCSetCStr(self: *const String, start: i32, reject: [:0]const u8) i32 {
        return c.al_ustr_find_cset_cstr(self.us, start, reject.ptr);
    }

    pub fn findReplace(self: *String, start: i32, findSrc: *const String, replace: *const String) bool {
        return c.al_ustr_find_replace(self.us, start, findSrc.us, replace.us);
    }

    pub fn assignSubstr(self: *String, other: *const String, start: i32, end: i32) bool {
        return c.al_ustr_assign_substr(self.us, other.us, start, end);
    }

    pub fn compare(self: *const String, other: *const String) i32 {
        return c.al_ustr_compare(self.us, other.us);
    }

    pub fn ncompare(self: *const String, other: *const String, n: i32) i32 {
        return c.al_ustr_ncompare(self.us, other.us, n);
    }

    pub fn equal(self: *const String, other: *const String) bool {
        return c.al_ustr_equal(self.us, other.us);
    }

    pub fn sizeUtf16(self: *const String) usize {
        return c.al_ustr_size_utf16(self.us);
    }

    pub fn encodeUtf16(self: *const String, buf: []u16) usize {
        return c.al_ustr_encode_utf16(self.us, buf.ptr, buf.len);
    }
};

/// Encode one codepoint into UTF-8. Returns number of bytes written.
pub fn utf8Encode(buf: []u8, codepoint: i32) usize {
    return c.al_utf8_encode(buf.ptr, codepoint);
}

pub fn utf8Width(codepoint: i32) usize {
    return c.al_utf8_width(codepoint);
}

pub fn utf16Encode(buf: []u16, codepoint: i32) usize {
    return c.al_utf16_encode(buf.ptr, codepoint);
}

pub fn utf16Width(codepoint: i32) usize {
    return c.al_utf16_width(codepoint);
}

/// A borrowed (non-owning) reference to a String, backed by a caller-provided
/// info buffer. Useful for zero-copy views into existing buffers, C strings or
/// substrings. The referenced source data must outlive the Ref.
pub const Ref = struct {
    info: c.ALLEGRO_USTR_INFO = undefined,
    _ref: *const c.ALLEGRO_USTR = undefined,

    pub fn fromBuffer(s: []const u8) Ref {
        var r: Ref = undefined;
        r._ref = c.al_ref_buffer(&r.info, s.ptr, s.len);
        return r;
    }

    pub fn fromCStr(s: [:0]const u8) Ref {
        var r: Ref = undefined;
        r._ref = c.al_ref_cstr(&r.info, s.ptr);
        return r;
    }

    pub fn fromSubstr(s: *const String, start: i32, end: i32) Ref {
        var r: Ref = undefined;
        r._ref = c.al_ref_ustr(&r.info, s.us, start, end);
        return r;
    }

    pub fn asString(self: *const Ref) String {
        return .{ .us = @constCast(self._ref) };
    }

    pub fn getPtr(self: *const Ref) *const c.ALLEGRO_USTR {
        return self._ref;
    }
};

test "refAllDecls" {
    std.testing.refAllDecls(String);
    std.testing.refAllDecls(Ref);
}
