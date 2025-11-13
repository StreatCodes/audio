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

const SessionError = error{
    BadRequest,
};

allocator: mem.Allocator,
/// Epoch time in milliseconds when the session is due to expire
expires: i64 = 0,
call_id: []u8 = "",
contacts: ArrayList(headers.Contact),
supported_methods: ArrayList(headers.Method),
connection: Connection,

pub fn init(allocator: mem.Allocator, connection: Connection, request: Request) !Session {
    return Session{
        .allocator = allocator,
        .contacts = ArrayList(headers.Contact).empty,
        .supported_methods = ArrayList(headers.Method).empty,
        .connection = connection,
        .call_id = try allocator.dupe(u8, request.call_id),
    };
}

pub fn deinit(self: *Session) void {
    self.allocator.free(self.call_id);
    self.contacts.deinit();
    self.supported_methods.deinit();
}

/// Sends a response back to the session's client
pub fn sendResponse(self: Session, response: Response) !void {
    var response_buffer = std.io.Writer.Allocating.init(self.allocator);
    try response.encode(&response_buffer.writer);

    debug.print("Response: [{s}]\n", .{response_buffer.written()});
    _ = try posix.sendto(self.connection.socket, response_buffer.written(), 0, &self.connection.address, self.connection.address_len);
}
