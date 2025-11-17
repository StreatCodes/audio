const std = @import("std");
const mem = std.mem;
const fmt = std.fmt;
const debug = std.debug;
const posix = std.posix;
const testing = std.testing;
const headers = @import("./headers.zig");
const Request = @import("./Request.zig");
const Response = @import("./Response.zig");
const Session = @import("./Session.zig");
const Connection = @import("./server.zig").Connection;

const Service = @This();
const Sessions = std.StringHashMap(Session);

const ServiceError = error{
    MaxForwardsExceeded,
};

allocator: std.mem.Allocator,
sessions: Sessions,
branch: []const u8,

pub fn init(allocator: mem.Allocator) !Service {
    const prefix = "z9hG4bK";
    var random_data: [20]u8 = undefined;

    var prng = std.Random.DefaultPrng.init(1337);
    prng.fill(&random_data);

    return Service{
        .allocator = allocator,
        .sessions = Sessions.init(allocator),
        .branch = try fmt.allocPrint(allocator, "{s}{x}", .{ prefix, random_data }),
    };
}

pub fn deinit(self: *Service) void {
    //TODO iterate all the session keys and deinit them
    //TODO iterate all the sessions and deinit them
    self.sessions.deinit();
    self.allocator.free(self.branch);
}

const Message = union(enum) {
    request: Request,
    response: Response,
};

pub fn sessionFromMessage(self: Service, message: Message) !?*Session {
    var session_id: []const u8 = undefined;
    switch (message) {
        .request => |request| session_id = try request.from.contact.identity(self.allocator),
        .response => |response| session_id = try response.from.contact.identity(self.allocator),
    }
    defer self.allocator.free(session_id);
    return self.sessions.getPtr(session_id);
}

pub fn findSessionFromId(self: Service, id: []const u8) ?Session {
    var session: ?Session = null;
    var sessions_iter = self.sessions.valueIterator();
    while (sessions_iter.next()) |sesh| {
        if (std.mem.eql(u8, sesh.identity, id)) {
            session = sesh.*;
        }
    }
    return session;
}

pub fn serverAddress(self: Service) headers.Address {
    _ = self;
    return headers.Address{
        .host = "localhost", //TODO do not hard code this!
        .port = 5060, //TODO do not hard code this!
    };
}

/// Accepts a SIP message for an established session. All SIP messages will get
/// routed through this to the appropriate handler for that method.
pub fn handleMessage(self: *Service, connection: Connection, message: []const u8) !void {
    if (mem.startsWith(u8, message, "SIP/2.0")) {
        var response = Response.init();
        defer response.deinit(self.allocator);
        try response.parse(self.allocator, message);

        try self.handleResponse(response);
    } else {
        var request = Request.init();
        defer request.deinit(self.allocator);
        try request.parse(self.allocator, message);

        self.handleRequest(connection, request) catch |err| {
            switch (err) {
                Session.SessionError.NotRegistered => {
                    // TODO this error handling can fail and crash the server
                    // This error is for cases where a session wasn't found. Create a temporary one to send a response.
                    const id = try request.from.contact.identity(self.allocator);
                    defer self.allocator.free(id);
                    debug.print("Recieved message from unregistered client {s}\n", .{id});
                    var temp_session = try Session.init(self.allocator, connection, request);
                    defer temp_session.deinit();

                    var response = try Response.initFromRequest(self.allocator, request);
                    response.status = .forbidden;
                    try temp_session.sendResponse(response);
                },
                Session.SessionError.RecipientNotFound => {
                    const session = try self.sessionFromMessage(.{ .request = request }) orelse unreachable;

                    var response = try Response.initFromRequest(self.allocator, request);
                    response.status = .not_found;
                    try session.sendResponse(response);
                },
                else => {
                    debug.print("Unknown error\n", .{});
                },
            }
        };
    }
}

fn handleResponse(self: *Service, response: Response) !void {
    switch (response.status) {
        .trying => {}, // Do nothing, we generate our own
        .ringing => try self.forwardResponse(response),
        .ok => try self.forwardResponse(response),
        else => {
            std.debug.print("Response not implemented {any}\n", .{response.status});
        },
    }
}

fn handleRequest(self: *Service, connection: Connection, request: Request) !void {
    switch (request.method) {
        .register => try self.handleRegisterRequest(connection, request),
        .invite => try self.handleInviteRequest(request),
        .ack => {}, //Do nothing
        else => try self.handleUnknownRequest(request),
    }
}

fn handleRegisterRequest(self: *Service, connection: Connection, request: Request) !void {
    const session_id = try request.from.contact.identity(self.allocator);

    //Check to see if a session exists for the remote address, if not create one
    var session = try self.sessionFromMessage(.{ .request = request }) orelse blk: {
        debug.print("REGISTER - {s} session created\n", .{session_id});
        var new_session = try Session.init(self.allocator, connection, request);
        try self.sessions.put(session_id, new_session);
        break :blk &new_session;
    };

    const session_duration: i64 = @intCast(request.expires * 1000);
    session.expires = std.time.milliTimestamp() + session_duration;

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

fn handleInviteRequest(self: *Service, request: Request) !void {
    const session = try self.sessionFromMessage(.{ .request = request }) orelse return Session.SessionError.NotRegistered;

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

    var recipient_session = self.findSessionFromId(to_identity) orelse {
        return Session.SessionError.RecipientNotFound;
    };

    var new_request = try request.dupe(self.allocator);
    new_request.max_forwards -= 1;
    // TODO update the URI line
    // std.debug.print("Contact: {any}\n", .{recipient_session.contact});
    // new_request.uri = try recipient_session.connection.getUri(self.allocator, recipient_session.contact.user);

    try new_request.via.insert(self.allocator, 0, .{
        .protocol = .udp,
        .address = self.serverAddress(),
        .branch = self.branch,
    });
    new_request.record_route = .{
        .address = self.serverAddress(),
        .lr = true,
    };

    if (new_request.max_forwards < 0) {
        return ServiceError.MaxForwardsExceeded;
    }

    try recipient_session.sendRequest(new_request);
}

fn handleUnknownRequest(self: Service, request: Request) !void {
    const session = try self.sessionFromMessage(.{ .request = request }) orelse return Session.SessionError.NotRegistered;

    //Process the message for the session
    // const session = sessions.getPtr(remote_address) orelse unreachable;
    var response = try Response.initFromRequest(self.allocator, request);
    defer response.deinit(self.allocator);
    response.status = .not_implemented;

    try session.sendResponse(response);
}

fn forwardResponse(self: *Service, response: Response) !void {
    const session = try self.sessionFromMessage(.{ .response = response }) orelse return Session.SessionError.NotRegistered;
    _ = session;

    const to_contact = response.to orelse return Request.RequestError.InvalidMessage; //TODO move this error to a MessageError type along with the union above
    const to_identity = try to_contact.contact.identity(self.allocator);
    defer self.allocator.free(to_identity);

    var recipient_session = self.findSessionFromId(to_identity) orelse {
        return Session.SessionError.RecipientNotFound;
    };

    try recipient_session.sendResponse(response); //TODO i probably need to update some fields here...
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
    var session = try Service.init(testing.allocator);
    defer session.deinit();
    try session.handleMessage(request, &response);

    //TODO make this more thorough
    try testing.expectEqual(response.status, Response.StatusCode.ok);
    try testing.expectEqualStrings(response.call_id, request.call_id);
    try testing.expectEqual(response.sequence.?.number, request.sequence.?.number);
}
