const std = @import("std");
const mem = std.mem;
const debug = std.debug;
const posix = std.posix;
const testing = std.testing;
const Request = @import("./Request.zig");
const Response = @import("./Response.zig");
const Session = @import("./Session.zig");
const Connection = @import("./server.zig").Connection;

const Service = @This();
const Sessions = std.StringHashMap(Session);

allocator: std.mem.Allocator,
sessions: Sessions,

pub fn init(allocator: mem.Allocator) Service {
    return Service{
        .allocator = allocator,
        .sessions = Sessions.init(allocator),
    };
}

pub fn deinit(self: *Service) void {
    //TODO iterate all the session keys and deinit them
    //TODO iterate all the sessions and deinit them
    self.sessions.deinit();
}

/// Accepts a SIP request for an established session and returns a response
/// if one should be sent back to the client. It is the callers responsibility
/// to clean up the response if one is returned. All SIP messages will get
/// routed through this to the appropriate handler for that method
pub fn handleMessage(self: *Service, connection: Connection, request: Request) !void {
    switch (request.method) {
        .register => try self.handleRegister(connection, request),
        .invite => try self.handleInvite(connection, request),
        .ack => {}, //Do nothing
        else => try self.handleUnknown(connection, request),
    }
}

fn handleRegister(self: *Service, connection: Connection, request: Request) !void {
    const address = try connection.getAddressAndPort(self.allocator);
    var session: *Session = undefined;

    //Check to see if a session exists for the remote address, if not create one
    if (!self.sessions.contains(address)) {
        debug.print("REGISTER - session created\n", .{});
        var new_session = try Session.init(self.allocator, connection, request);
        try self.sessions.put(address, new_session);
        session = &new_session;
    } else {
        debug.print("REGISTER - session update\n", .{});
        defer self.allocator.free(address);
        session = self.sessions.getPtr(address) orelse unreachable;
        //validate call-id is eql - apparently this is not necessary
    }

    const session_duration: i64 = @intCast(request.expires * 1000);
    session.expires = std.time.milliTimestamp() + session_duration;

    session.contacts.clearRetainingCapacity();
    for (request.contact.items) |contact_header| {
        try session.contacts.append(self.allocator, contact_header.contact);
    }
    session.contacts.clearRetainingCapacity();
    for (request.allow.items) |allowed_method| {
        try session.supported_methods.append(self.allocator, allowed_method);
    }

    var response = try Response.initFromRequest(self.allocator, request);
    defer response.deinit(self.allocator);

    //Set expiries on reponse
    for (request.contact.items) |contact_header| {
        try response.contact.append(self.allocator, .{
            .contact = contact_header.contact,
            .expires = request.expires,
        });
    }

    try session.sendResponse(response);
}

fn handleInvite(self: *Service, connection: Connection, request: Request) !void {
    const address = connection.getAddressAndPort(self.allocator) catch return Request.RequestError.InvalidMessage;
    const session = self.sessions.get(address) orelse return Session.SessionError.NotFound;

    // Let the send know we're trying to call the recipient
    var trying_response = try Response.initFromRequest(self.allocator, request);
    defer trying_response.deinit(self.allocator);
    trying_response.status = .trying;
    try session.sendResponse(trying_response);

    // Look up recipient
    // TODO maybe a better way
    const to_contact = request.to orelse return Request.RequestError.InvalidMessage;
    const to_identity = try to_contact.contact.identity(self.allocator);
    defer self.allocator.free(to_identity);

    var recipient_session: ?Session = null;
    var sessions_iter = self.sessions.valueIterator();
    while (sessions_iter.next()) |sesh| {
        if (std.mem.eql(u8, sesh.identity, to_identity)) {
            recipient_session = sesh.*;
        }
    }

    if (recipient_session == null) return Session.SessionError.NotFound;

    var new_request = try request.dupe(self.allocator);
    new_request.max_forwards -= 1;
    // TODO append server via. make this a function on Request
    // TODO add record route. make this a function on Request
    // TODO check max_forwards less than one. make this a function on Request

    try recipient_session.?.sendRequest(new_request);
}

fn handleUnknown(self: Service, connection: Connection, request: Request) !void {
    const address = try connection.getAddressAndPort(self.allocator);
    const session = self.sessions.get(address) orelse unreachable; //TODO return bad request here

    //TODO check incoming request is registered user!!!!
    //Process the message for the session
    // const session = sessions.getPtr(remote_address) orelse unreachable;
    var response = try Response.initFromRequest(self.allocator, request);
    defer response.deinit(self.allocator);
    response.status = .not_implemented;

    try session.sendResponse(response);
}

test "Server creates new session from REGISTER request" {
    const request_text = "REGISTER sip:localhost SIP/2.0\r\n" ++
        "Via: SIP/2.0/UDP 172.20.10.4:51503;rport;branch=z9hG4bKPjDdUL.6kHzjJFszmWr9AGotAlsZvHTB0P\r\n" ++
        "Max-Forwards: 70\r\n" ++
        "From: \"Streats\" <sip:streats@localhost>;tag=fhKG9FMFGbyIi5LZTlwro5qigCxoFqwf\r\n" ++
        "To: \"Streats\" <sip:streats@localhost>\r\n" ++
        "Call-ID: Fb5KdYo-eWr4WVTWTv0vwxwi.XvJFoGf\r\n" ++
        "CSeq: 34848 REGISTER\r\n" ++
        "User-Agent: Telephone 1.6\r\n" ++
        "Contact: \"Streats\" <sip:streats@172.20.10.4:51503;ob>\r\n" ++
        "Expires: 0\r\n" ++
        "Content-Length:  0\r\n" ++
        "\r\n";

    var request = Request.init(testing.allocator);
    defer request.deinit();
    try request.parse(request_text);

    var response = Response.init(testing.allocator);
    defer response.deinit();
    var session = Service.init(testing.allocator);
    defer session.deinit();
    try session.handleMessage(request, &response);

    //TODO make this more thorough
    try testing.expectEqual(response.status, Response.StatusCode.ok);
    try testing.expectEqualStrings(response.call_id, request.call_id);
    try testing.expectEqual(response.sequence.?.number, request.sequence.?.number);
}
