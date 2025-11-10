const std = @import("std");
const mem = std.mem;
const debug = std.debug;
const testing = std.testing;
const Response = @import("./Response.zig");
const Request = @import("./Request.zig");
const headers = @import("./headers.zig");
const ArrayList = std.ArrayList;
const Session = @This();

const SessionError = error{
    BadRequest,
};

allocator: mem.Allocator,
sequence: u32 = 0,
/// Epoch time in milliseconds when the session is due to expire
expires: i64 = 0,
call_id: []u8 = "",
contacts: ArrayList(headers.Contact),
supported_methods: ArrayList(headers.Method),

pub fn init(allocator: mem.Allocator) Session {
    return Session{
        .allocator = allocator,
        .contacts = ArrayList(headers.Contact).empty,
        .supported_methods = ArrayList(headers.Method).empty,
    };
}

pub fn deinit(self: *Session) void {
    self.allocator.free(self.call_id);
    self.contacts.deinit();
    self.supported_methods.deinit();
}

/// Accepts a SIP request for an established session and returns a response
/// if one should be sent back to the client. It is the callers responsibility
/// to clean up the response if one is returned. All SIP messages will get
/// routed through this to the appropriate handler for that method
pub fn handleMessage(self: *Session, request: Request) !?Response {
    switch (request.method) {
        .register => return try self.handleRegister(request),
        .ack => return null, //Do nothing
        else => return try self.handleUnknown(request),
    }
}

fn handleRegister(self: *Session, request: Request) !Response {
    var response = try Response.initFromRequest(self.allocator, request);
    errdefer response.deinit(self.allocator);

    debug.print("REGISTER - session update\n", .{});
    const new_session = self.call_id.len == 0;

    if (new_session) {
        self.call_id = try self.allocator.dupe(u8, request.call_id);
        const sequence = request.sequence orelse return SessionError.BadRequest;
        self.sequence = sequence.number;
    } else {
        //validate call-id is eql
        //validate sequence += 1 //make this a function if it's applicable to all messages

    }

    const session_duration: i64 = @intCast(request.expires * 1000);
    self.expires = std.time.milliTimestamp() + session_duration;

    self.contacts.clearRetainingCapacity();
    for (request.contact.items) |contact_header| {
        try self.contacts.append(self.allocator, contact_header.contact);
    }
    //TODO surely this can be improved
    self.supported_methods.clearRetainingCapacity();
    for (request.allow.items) |allowed_method| {
        try self.supported_methods.append(self.allocator, allowed_method);
    }

    //Set expiries on reponse
    for (request.contact.items) |contact_header| {
        try response.contact.append(self.allocator, .{
            .contact = contact_header.contact,
            .expires = request.expires,
        });
    }

    return response;
}

fn handleUnknown(self: Session, request: Request) !Response {
    var response = try Response.initFromRequest(self.allocator, request);
    response.status = .not_implemented;

    return response;
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
    var session = Session.init(testing.allocator);
    defer session.deinit();
    try session.handleMessage(request, &response);

    //TODO make this more thorough
    try testing.expectEqual(response.status, Response.StatusCode.ok);
    try testing.expectEqualStrings(response.call_id, request.call_id);
    try testing.expectEqual(response.sequence.?.number, request.sequence.?.number);
}
