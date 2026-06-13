const std = @import("std");
const Response = @import("./Response.zig");
const Request = @import("./Request.zig");
const headers = @import("./headers.zig");
const Connection = @import("./server.zig").Connection;
const Message = @import("./service.zig").Message;
const ServiceError = @import("./service.zig").ServiceError;
const Registrar = @This();

map: std.StringHashMap(Registration),

pub fn init(gpa: std.mem.Allocator) Registrar {
    return .{
        .map = .init(gpa),
    };
}

pub fn deinit(registrar: *Registrar, gpa: std.mem.Allocator) void {
    var iter = registrar.map.iterator();
    while (iter.next()) |entry| {
        gpa.free(entry.key_ptr.*);
        entry.value_ptr.deinit(gpa);
    }
    registrar.map.deinit();
}

pub fn registrationFromMessage(self: Registrar, message: Message) !?*Registration {
    var session_id: []const u8 = undefined;
    switch (message) {
        .request => |request| session_id = try request.from.contact.identity(self.allocator),
        .response => |response| session_id = try response.from.contact.identity(self.allocator),
    }
    defer self.allocator.free(session_id);
    return self.sessions.getPtr(session_id);
}

pub fn findSessionFromId(self: Registrar, id: []const u8) ?Registration {
    var session: ?Registration = null;
    var sessions_iter = self.sessions.valueIterator();
    while (sessions_iter.next()) |sesh| {
        if (std.mem.eql(u8, sesh.identity, id)) {
            session = sesh.*;
        }
    }
    return session;
}

pub fn rejectUnregisteredRequest(gpa: std.mem.Allocator, io: std.Io, connection: Connection, request: Request) !void {
    const id = try request.from.contact.identity(gpa);
    defer gpa.free(id);
    std.debug.print("Recieved message from unregistered client {s}\n", .{id});

    var response = try Response.initFromRequest(gpa, request);
    response.status = .forbidden;

    var buffer: std.ArrayList(u8) = try .initCapacity(gpa, 4096);
    defer buffer.deinit(gpa);
    try response.encode(gpa, &buffer);
    try connection.socket.send(io, &connection.address, buffer.items);
}

pub fn getOrCreate(registrar: *Registrar, gpa: std.mem.Allocator, connection: Connection, request: Request) !*Registration {
    const existing_registration = try registrar.sessionFromMessage(.{ .request = request });
    if (existing_registration) |existing| return existing;

    const session_id = try request.from.contact.identity(gpa);
    std.debug.print("REGISTER - {s} session created\n", .{session_id});

    const registration = try Registration.init(gpa, connection, request);
    try registrar.map.put(session_id, registration);
    return registration;
}

pub const Registration = struct {
    /// Epoch time in milliseconds when the session is due to expire
    expires: i64 = 0,
    identity: []const u8,
    call_id: []u8 = "",
    contact: headers.Contact,
    connection: Connection,

    pub fn init(gpa: std.mem.Allocator, connection: Connection, request: Request) !*Registration {
        const to = request.to orelse return Request.RequestError.InvalidMessage;

        if (request.contact.items.len == 0) {
            return ServiceError.BadRequest;
        }

        const registration = try gpa.create(Registration);

        registration.* = .{
            .identity = try to.contact.identity(gpa),
            .contact = request.contact.items[0].contact,
            .connection = connection,
            .call_id = try gpa.dupe(u8, request.call_id),
        };

        return registration;
    }

    pub fn deinit(registration: *Registration, gpa: std.mem.Allocator) void {
        gpa.free(registration.call_id);
        gpa.free(registration.identity);
    }

    pub fn setExpiration(registration: *Registration, io: std.Io, seconds: u32) void {
        const ts = std.Io.Timestamp.now(io, .real);
        registration.expires = ts.addDuration(std.Io.Duration.fromSeconds(@intCast(seconds))).toMilliseconds();
    }

    /// Send a message to the registered client
    pub fn sendMessage(self: Registration, allocator: std.mem.allocator, io: std.Io, message: Message) !void {
        var buffer: std.ArrayList(u8) = try .initCapacity(allocator, 4096);
        defer buffer.deinit(allocator);
        switch (message) {
            .request => |request| try request.encode(allocator, &buffer),
            .response => |response| try response.encode(allocator, &buffer),
        }

        try self.connection.socket.send(io, &self.connection.address, buffer.items);

        std.debug.print("Sent: [{s}]\n", .{buffer.items});
    }
};
