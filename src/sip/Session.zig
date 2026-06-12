const std = @import("std");
const mem = std.mem;
const debug = std.debug;
const testing = std.testing;
const posix = std.posix;
const Response = @import("./Response.zig");
const Request = @import("./Request.zig");
const headers = @import("./headers.zig");
const Connection = @import("./server.zig").Connection;
const ArrayList = std.ArrayList;
const Session = @This();

pub const SessionError = error{
    InvalidSession,
    NotRegistered,
    RecipientNotFound,
};

allocator: mem.Allocator,
io: std.Io,
/// Epoch time in milliseconds when the session is due to expire
expires: i64 = 0,
identity: []const u8,
call_id: []u8 = "",
contact: headers.Contact,
connection: Connection,

pub fn init(allocator: mem.Allocator, io: std.Io, connection: Connection, request: Request) !Session {
    const to = request.to orelse return Request.RequestError.InvalidMessage;

    if (request.contact.items.len == 0) {
        return SessionError.InvalidSession;
    }

    return Session{
        .allocator = allocator,
        .io = io,
        .identity = try to.contact.identity(allocator),
        .contact = request.contact.items[0].contact,
        .connection = connection,
        .call_id = try allocator.dupe(u8, request.call_id),
    };
}

pub fn deinit(self: *Session) void {
    self.allocator.free(self.call_id);
    self.allocator.free(self.identity);
}

/// Sends a response to the session's client
pub fn sendResponse(self: Session, response: Response) !void {
    var buffer: std.ArrayList(u8) = try .initCapacity(self.allocator, 4096);
    defer buffer.deinit(self.allocator);
    try response.encode(self.allocator, &buffer);

    try self.connection.socket.send(self.io, &self.connection.address, buffer.items);

    debug.print("Sent: [{s}]\n", .{buffer.items});
}

/// Sends a request to the session's client
pub fn sendRequest(self: Session, request: Request) !void {
    var buffer: std.ArrayList(u8) = try .initCapacity(self.allocator, 4096);
    defer buffer.deinit(self.allocator);
    try request.encode(self.allocator, &buffer);

    debug.print("Sent: [{s}]\n", .{buffer.items});
    try self.connection.socket.send(self.io, &self.connection.address, buffer.items);
}
