const std = @import("std");
const Self = @This();

slice: []const u8,
offset: usize = 0,

pub fn init(slice: []const u8) Self {
    return Self{
        .slice = slice,
    };
}

pub fn get(self: *Self) ?u8 {
    if (self.offset >= self.slice.len)
        return null;
    const c = self.slice[self.offset];
    self.offset += 1;
    return c;
}

pub fn peek(self: Self) ?u8 {
    if (self.offset >= self.slice.len)
        return null;
    return self.slice[self.offset];
}

pub fn readWhile(self: *Self, comptime predicate: fn (u8) bool) []const u8 {
    const start = self.offset;
    var end = start;
    while (end < self.slice.len and predicate(self.slice[end])) {
        end += 1;
    }
    self.offset = end;
    return self.slice[start..end];
}

pub fn readUntil(self: *Self, comptime predicate: fn (u8) bool) []const u8 {
    const start = self.offset;
    var end = start;
    while (end < self.slice.len and !predicate(self.slice[end])) {
        end += 1;
    }
    self.offset = end;
    return self.slice[start..end];
}

/// Reads until the scalar. The returned slice excludes the scalar.
/// The new offset will be the index of the scalar
pub fn readUntilScalar(self: *Self, scalar: u8) []const u8 {
    const start = self.offset;
    var end = start;
    while (end < self.slice.len and self.slice[end] != scalar) {
        end += 1;
    }
    self.offset = end;
    return self.slice[start..end];
}

/// Reads until the scalar. The returned slice excludes the scalar.
/// The new offset will be the index after the scalar
pub fn readUntilScalarExcluding(self: *Self, scalar: u8) []const u8 {
    const result = self.readUntilScalar(scalar);
    if (self.offset < self.slice.len) self.offset += 1;
    return result;
}

/// Reads until the scalar. The returned slice includes the scalar.
/// The new offset will be the index after the scalar
pub fn readUntilScalarConsuming(self: *Self, scalar: u8) []const u8 {
    const start = self.offset;
    _ = self.readUntilScalar(scalar);
    if (self.offset < self.slice.len) self.offset += 1;
    return self.slice[start..self.offset];
}

pub fn readUntilEof(self: *Self) []const u8 {
    const start = self.offset;
    self.offset = self.slice.len;
    return self.slice[start..];
}

pub fn peekPrefix(self: Self, prefix: []const u8) bool {
    if (self.offset + prefix.len > self.slice.len)
        return false;
    return std.mem.eql(u8, self.slice[self.offset..][0..prefix.len], prefix);
}

pub fn rest(self: Self) []const u8 {
    const start = self.offset;
    return self.slice[start..];
}
